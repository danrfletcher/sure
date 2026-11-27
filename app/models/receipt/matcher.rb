# frozen_string_literal: true

# Works the receipt queue for one family: links each waiting receipt to the
# transaction it belongs to, or moves it to "needs attention" with a reason.
#
# Rules, in order:
# 1. A receipt without a total or a date can't be matched automatically.
# 2. Candidates are posted, non-pending transaction entries (money out) on
#    visible accounts other than the excluded ones, dated from a few days before
#    the receipt to the end of its wait window, and not already holding a receipt.
# 3. Amount: exact in the same currency; else a different currency within
#    FX_TOLERANCE of the receipt converted at the transaction day's rate; else a
#    bank amount up to TIP_TOLERANCE over the receipt, only when the merchant
#    matches. A looser kind is only used when no stricter kind has candidates.
# 4. Narrow by merchant when any candidate matches it, then take the closest
#    date. Candidates with the same amount and merchant are interchangeable and
#    are taken in date order (receipts are worked oldest first, one per
#    transaction). Any other tie goes to a person.
# 5. No match once the wait window has passed: needs attention, keeping the
#    nearest misses.
class Receipt::Matcher
  FX_TOLERANCE = BigDecimal("0.03")
  TIP_TOLERANCE = BigDecimal("0.20")
  DAYS_BEFORE_RECEIPT = 3
  MAX_NEAR_MISSES = 3
  NEAR_MISS_AMOUNT_RATIO = BigDecimal("0.25")
  MIN_MERCHANT_LENGTH = 3

  Candidate = Struct.new(:entry, :kind, keyword_init: true)

  def initialize(family, today: Date.current, excluded_account_ids: nil)
    @family = family
    @today = today
    @excluded_account_ids = excluded_account_ids || Receipt::ExcludedAccounts.new(family).account_ids
  end

  def run
    result = Hash.new(0)

    @family.receipts.waiting.order(:receipt_date, :created_at, :id).each do |receipt|
      outcome = process(receipt)
      result[outcome] += 1
    end

    result
  end

  private

    def process(receipt)
      if receipt.total.blank? || receipt.receipt_date.blank?
        receipt.flag_for_attention!(reason: "missing_details")
        return :needs_attention
      end

      candidates = amount_candidates(receipt)
      choice = choose(receipt, candidates)

      if choice.is_a?(Candidate)
        attach_and_match(receipt, choice.entry.entryable)
      elsif choice == :ambiguous
        tied = candidates.map(&:entry)
        receipt.flag_for_attention!(reason: "ambiguous", candidates: near_miss_payload(tied.first(MAX_NEAR_MISSES * 2), receipt))
        :needs_attention
      elsif @today > receipt.wait_deadline
        receipt.flag_for_attention!(reason: "no_transaction_found", candidates: near_miss_payload(near_misses(receipt), receipt))
        :needs_attention
      else
        :waiting
      end
    end

    def attach_and_match(receipt, transaction)
      if transaction.attachments.size >= Transaction::MAX_ATTACHMENTS_PER_TRANSACTION
        receipt.flag_for_attention!(reason: "transaction_attachment_limit", candidates: near_miss_payload([ transaction.entry ], receipt))
        return :needs_attention
      end

      Receipt.transaction do
        transaction.attachments.attach(receipt.file.blob)
        raise ActiveRecord::Rollback unless transaction.attachments_attachments.exists?(blob_id: receipt.file.blob.id)

        receipt.mark_matched!(transaction)
      end

      return :matched if receipt.matched?

      receipt.flag_for_attention!(reason: "attach_failed", candidates: near_miss_payload([ transaction.entry ], receipt))
      :needs_attention
    end

    # --- candidates ---

    def candidate_entries(receipt)
      from = receipt.receipt_date - DAYS_BEFORE_RECEIPT
      to = receipt.wait_deadline

      Entry.visible
        .excluding_pending
        .where(accounts: { family_id: @family.id })
        .where.not(account_id: @excluded_account_ids)
        .where(entryable_type: "Transaction", excluded: false, date: from..to)
        .where("entries.amount > 0")
        .where.not(entryable_id: Receipt.where.not(matched_transaction_id: nil).select(:matched_transaction_id))
        .preload(entryable: :merchant)
        .order(:date, :created_at, :id)
        .to_a
    end

    def amount_candidates(receipt)
      entries = candidate_entries(receipt)
      tiers = { exact: [], fx: [], tip: [] }

      entries.each do |entry|
        kind = amount_kind(receipt, entry)
        tiers[kind] << Candidate.new(entry: entry, kind: kind) if kind
      end

      tiers.values.find(&:any?) || []
    end

    def amount_kind(receipt, entry)
      total = receipt.total.to_d
      amount = entry.amount.to_d

      if receipt.currency.blank? || receipt.currency == entry.currency
        return :exact if amount.round(2) == total.round(2)
        return :tip if amount > total && amount <= total * (1 + TIP_TOLERANCE) && merchant_match?(receipt, entry)
      else
        return :fx if within_fx_tolerance?(receipt, entry, total, amount)
      end

      nil
    end

    def within_fx_tolerance?(receipt, entry, total, amount)
      rate = ExchangeRate.find_or_fetch_rate(from: receipt.currency, to: entry.currency, date: entry.date)&.rate
      return false if rate.blank?

      expected = total * rate.to_d
      expected.positive? && (amount - expected).abs <= expected * FX_TOLERANCE
    end

    # --- choosing ---

    def choose(receipt, candidates)
      return nil if candidates.empty?
      return candidates.first if candidates.one?

      by_merchant = candidates.select { |candidate| merchant_match?(receipt, candidate.entry) }
      narrowed = by_merchant.presence || candidates

      return narrowed.first if narrowed.one?
      return closest_in_date(receipt, narrowed) if interchangeable?(narrowed)
      return :ambiguous unless by_merchant.any?

      best = narrowed.group_by { |candidate| (candidate.entry.date - receipt.receipt_date).abs }.min_by(&:first).last
      best.one? ? best.first : :ambiguous
    end

    def closest_in_date(receipt, candidates)
      candidates.min_by { |candidate| [ (candidate.entry.date - receipt.receipt_date).abs, candidate.entry.date, candidate.entry.created_at, candidate.entry.id ] }
    end

    def interchangeable?(candidates)
      candidates.map { |candidate| [ candidate.entry.amount.to_d, normalize(candidate.entry.name), normalize(merchant_name(candidate.entry)) ] }.uniq.one?
    end

    # --- merchant text ---

    NOISE_WORDS = %w[ltd limited plc inc llc the uk gb].freeze

    def merchant_match?(receipt, entry)
      wanted = normalize(receipt.merchant)
      return false if wanted.length < MIN_MERCHANT_LENGTH

      [ entry.name, merchant_name(entry) ].any? do |text|
        found = normalize(text)
        found.length >= MIN_MERCHANT_LENGTH && (found.include?(wanted) || wanted.include?(found))
      end
    end

    def merchant_name(entry)
      entry.entryable.try(:merchant)&.name
    end

    def normalize(text)
      words = text.to_s.downcase.gsub(/[^a-z0-9 ]/, " ").split - NOISE_WORDS
      words.join
    end

    # --- near misses ---

    def near_misses(receipt)
      total = receipt.total.to_d

      candidate_entries(receipt).filter_map do |entry|
        by_merchant = merchant_match?(receipt, entry)
        close_amount = receipt.currency.blank? || receipt.currency == entry.currency
        close_amount &&= total.positive? && (entry.amount.to_d - total).abs <= total * NEAR_MISS_AMOUNT_RATIO
        next unless by_merchant || close_amount

        [ entry, by_merchant ? 0 : 1, (entry.amount.to_d - total).abs ]
      end.sort_by { |_entry, merchant_rank, difference| [ merchant_rank, difference ] }.first(MAX_NEAR_MISSES).map(&:first)
    end

    def near_miss_payload(entries, receipt)
      entries.map do |entry|
        {
          "transaction_id" => entry.entryable_id,
          "name" => entry.name,
          "date" => entry.date.iso8601,
          "amount" => entry.amount.to_s,
          "currency" => entry.currency,
          "merchant_match" => merchant_match?(receipt, entry)
        }
      end
    end
end
