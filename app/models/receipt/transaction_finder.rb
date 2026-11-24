# frozen_string_literal: true

# Transactions a person can pick from when matching a receipt by hand: searched
# by name, amount and date with the same filters as the Transactions page,
# limited to accounts the user can write to and to transactions that don't hold
# a receipt yet.
class Receipt::TransactionFinder
  LIMIT = 25
  DEFAULT_DAYS_BEFORE = 7

  def initialize(receipt, user:, params: nil)
    @receipt = receipt
    @user = user
    @params = params
  end

  # The filter values shown in the form: what was searched, or sensible
  # defaults taken from the receipt on first load.
  def filters
    @filters ||= if @params.nil?
      defaults
    else
      @params.slice(:search, :amount, :start_date, :end_date).to_h.symbolize_keys.transform_values { |value| value.to_s.strip }
    end
  end

  def transactions
    search = Transaction::Search.new(
      @receipt.family,
      filters: filters.merge(amount_operator: "equal"),
      accessible_account_ids: writable_account_ids
    )

    Transaction
      .where(id: search.transactions_scope.select(:id))
      .where.not(id: Receipt.where.not(matched_transaction_id: nil).select(:matched_transaction_id))
      .joins(:entry)
      .includes(entry: :account)
      .order("entries.date DESC", "entries.created_at DESC")
      .limit(LIMIT)
  end

  # Whether the user may match this receipt to the transaction.
  def pickable?(transaction)
    return false unless writable_account_ids.where(id: transaction.entry.account_id).exists?
    return false if Receipt.where(matched_transaction_id: transaction.id).exists?

    @receipt.family.transactions.exists?(id: transaction.id)
  end

  private

    def defaults
      date = @receipt.receipt_date
      {
        search: @receipt.merchant.to_s,
        amount: "",
        start_date: date ? (date - DEFAULT_DAYS_BEFORE).iso8601 : "",
        end_date: date ? (date + @receipt.wait_days).iso8601 : ""
      }
    end

    def writable_account_ids
      @writable_account_ids ||= @receipt.family.accounts.writable_by(@user).select(:id)
    end
end
