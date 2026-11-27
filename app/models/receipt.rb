# frozen_string_literal: true

require "digest/sha2"

# A receipt parked in a queue until the transaction it belongs to turns up.
# Intakes (photo classifier, email capture) post receipts here; a nightly job
# matches them to transactions.
class Receipt < ApplicationRecord
  MAX_FILE_SIZE = Transaction::MAX_ATTACHMENT_SIZE
  ALLOWED_CONTENT_TYPES = Transaction::ALLOWED_CONTENT_TYPES

  belongs_to :family
  belongs_to :matched_transaction, class_name: "Transaction", optional: true

  has_one_attached :file, dependent: :purge_later

  enum :status, {
    waiting: "waiting",
    archived: "archived",
    needs_attention: "needs_attention",
    matched: "matched",
    dismissed: "dismissed"
  }, validate: true, default: "waiting"

  enum :source, { photo: "photo", email: "email" }, validate: true

  before_validation :normalize_currency

  validates :filename, :content_type, presence: true
  validates :byte_size, numericality: { greater_than: 0, less_than_or_equal_to: MAX_FILE_SIZE }
  validates :content_type, inclusion: { in: ALLOWED_CONTENT_TYPES }
  validates :content_sha256,
            format: { with: /\A[0-9a-f]{64}\z/ },
            uniqueness: { scope: :family_id }
  validates :total, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :currency, format: { with: /\A[A-Z]{3}\z/ }, allow_nil: true
  validates :attention_reason, presence: true, if: :needs_attention?
  validates :matched_transaction, presence: true, if: :matched?
  validate :file_attached
  validate :matched_transaction_belongs_to_family

  scope :ordered, -> { order(created_at: :desc) }
  # Receipts the matcher still has to work on
  scope :in_queue, -> { where(status: :waiting) }

  class << self
    def sha256_of(content)
      Digest::SHA256.hexdigest(content)
    end

    # Stores a receipt file once per family. Posting the same bytes again
    # returns the receipt that already exists instead of making a second one.
    # Returns [receipt, created].
    def intake!(family:, content:, filename:, content_type:, **attributes)
      sha = sha256_of(content)
      existing = family.receipts.find_by(content_sha256: sha)
      return [ existing, false ] if existing

      receipt = family.receipts.build(
        attributes.merge(
          filename: filename,
          content_type: content_type,
          byte_size: content.bytesize,
          content_sha256: sha
        )
      )
      receipt.file.attach(io: StringIO.new(content), filename: filename, content_type: content_type)
      receipt.save!
      [ receipt, true ]
    rescue ActiveRecord::RecordNotUnique
      [ family.receipts.find_by!(content_sha256: sha), false ]
    end
  end

  # Waiting receipts leave the queue for "needs Dan" with a reason and the
  # closest near-misses (an array of small hashes, e.g. transaction id + why).
  def flag_for_attention!(reason:, candidates: [])
    update!(status: :needs_attention, attention_reason: reason, candidates: candidates)
  end

  def archive!(reason: nil)
    update!(status: :archived, attention_reason: reason, candidates: [])
  end

  def dismiss!
    update!(status: :dismissed, attention_reason: nil, candidates: [])
  end

  def mark_matched!(transaction)
    update!(status: :matched, matched_transaction: transaction, matched_at: Time.current, attention_reason: nil, candidates: [])
  end

  def requeue!
    update!(status: :waiting, matched_transaction: nil, matched_at: nil, attention_reason: nil, candidates: [])
  end

  private

    def normalize_currency
      self.currency = currency.to_s.strip.upcase.presence
    end

    def file_attached
      errors.add(:file, :blank) unless file.attached?
    end

    def matched_transaction_belongs_to_family
      return if matched_transaction.blank? || family.blank?

      unless family.transactions.exists?(id: matched_transaction.id)
        errors.add(:matched_transaction, :invalid)
      end
    end
end
