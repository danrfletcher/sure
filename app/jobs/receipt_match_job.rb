# frozen_string_literal: true

# Nightly: links waiting receipts to the transactions that have arrived since
# the last run and flags the ones that waited too long. See Receipt::Matcher.
class ReceiptMatchJob < ApplicationJob
  queue_as :scheduled

  def perform
    Family.where(id: Receipt.waiting.select(:family_id)).find_each do |family|
      Receipt::Matcher.new(family).run
    rescue StandardError => e
      Rails.logger.error("ReceiptMatchJob failed for family #{family.id}: #{e.class}: #{e.message}")
    end
  end
end
