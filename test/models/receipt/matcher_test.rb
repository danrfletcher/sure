require "test_helper"

RakeTaskTestHelper.load_task("receipts:requeue_archived", "receipts")

class Receipt::MatcherTest < ActiveSupport::TestCase
  include EntriesTestHelper
  include ActiveJob::TestHelper

  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
    @today = Date.current
  end

  def queue(total:, merchant: "Pret A Manger", days_ago: 2, currency: "USD", klarna: false, source: :photo, **attributes)
    receipt, = Receipt.intake!(
      family: @family, content: "%PDF-1.4 #{SecureRandom.hex(8)}", filename: "r.pdf", content_type: "application/pdf",
      source: source, merchant: merchant, total: total, currency: currency, klarna: klarna,
      receipt_date: @today - days_ago, **attributes
    )
    receipt
  end

  def spend(amount:, name: "PRET A MANGER 123", days_ago: 1, currency: "USD", account: @account, merchant: nil)
    create_transaction(account: account, name: name, amount: amount, currency: currency, date: @today - days_ago, merchant: merchant)
  end

  def run_matcher(**options)
    Receipt::Matcher.new(@family, today: @today, **options).run
  end

  test "an exact amount links the receipt and attaches the same blob without copying it" do
    receipt = queue(total: 37.41)
    entry = spend(amount: 37.41)

    assert_no_difference "ActiveStorage::Blob.count" do
      result = run_matcher
      assert_equal 1, result[:matched]
    end

    receipt.reload
    assert receipt.matched?
    assert_equal entry.entryable, receipt.matched_transaction
    assert_equal [ receipt.file.blob.id ], entry.entryable.attachments.map { |attachment| attachment.blob.id }
  end

  test "a receipt's blob stays on the transaction after the receipt is destroyed" do
    receipt = queue(total: 37.42)
    entry = spend(amount: 37.42)
    run_matcher

    perform_enqueued_jobs { receipt.reload.destroy! }

    assert entry.entryable.reload.attachments.attached?
    assert entry.entryable.attachments.first.download.start_with?("%PDF")
  end

  test "different currencies match within 3 percent of the transaction day's rate" do
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: @today - 1, rate: 1.10)
    receipt = queue(total: 100, currency: "EUR", merchant: nil)
    entry = spend(amount: 113.3, name: "SOME SHOP") # 3% over 110

    run_matcher

    assert_equal entry.entryable, receipt.reload.matched_transaction
  end

  test "different currencies do not match beyond 3 percent" do
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: @today - 1, rate: 1.10)
    receipt = queue(total: 100, currency: "EUR", merchant: nil)
    spend(amount: 113.5, name: "SOME SHOP") # just over 3% over 110

    run_matcher

    assert receipt.reload.waiting?
  end

  test "no exchange rate means no foreign-currency match" do
    ExchangeRate.stubs(:find_or_fetch_rate).returns(nil)
    receipt = queue(total: 100, currency: "EUR", merchant: nil)
    spend(amount: 110, name: "SOME SHOP")

    run_matcher

    assert receipt.reload.waiting?
  end

  test "a tip up to 20 percent over the total matches when the merchant matches" do
    receipt = queue(total: 50, merchant: "Dishoom")
    entry = spend(amount: 60, name: "DISHOOM KINGS CROSS")

    run_matcher

    assert_equal entry.entryable, receipt.reload.matched_transaction
  end

  test "a tip over 20 percent does not match" do
    receipt = queue(total: 50, merchant: "Dishoom")
    spend(amount: 60.5, name: "DISHOOM KINGS CROSS")

    run_matcher

    assert receipt.reload.waiting?
  end

  test "a tip needs the merchant to match" do
    receipt = queue(total: 50, merchant: "Dishoom")
    spend(amount: 55, name: "SOMEWHERE ELSE")

    run_matcher

    assert receipt.reload.waiting?
  end

  test "an exact amount beats a tip candidate" do
    receipt = queue(total: 50, merchant: "Dishoom")
    spend(amount: 55, name: "DISHOOM KINGS CROSS", days_ago: 1)
    exact = spend(amount: 50, name: "DISHOOM KINGS CROSS", days_ago: 0)

    run_matcher

    assert_equal exact.entryable, receipt.reload.matched_transaction
  end

  test "the merchant narrows the candidates before the date does" do
    receipt = queue(total: 12.34, merchant: "Pret A Manger", days_ago: 3)
    spend(amount: 12.34, name: "TESCO STORES", days_ago: 3) # closest date, wrong merchant
    right = spend(amount: 12.34, name: "PRET A MANGER 5", days_ago: 1)

    run_matcher

    assert_equal right.entryable, receipt.reload.matched_transaction
  end

  test "the merchant can come from the transaction's merchant record" do
    receipt = queue(total: 21.43, merchant: "Netflix")
    entry = spend(amount: 21.43, name: "CARD PAYMENT 8841", merchant: merchants(:netflix))

    run_matcher

    assert_equal entry.entryable, receipt.reload.matched_transaction
  end

  test "with several merchant matches the closest date wins" do
    receipt = queue(total: 9.87, merchant: "Pret", days_ago: 5)
    spend(amount: 9.87, name: "PRET A MANGER 1", days_ago: 0)
    near = spend(amount: 9.87, name: "PRET 22", days_ago: 4)
    spend(amount: 9.87, name: "PRET 33", days_ago: 1)

    run_matcher

    assert_equal near.entryable, receipt.reload.matched_transaction
  end

  test "identical candidates are linked in date order, one receipt per transaction" do
    first_receipt = queue(total: 4.55, days_ago: 6)
    second_receipt = queue(total: 4.55, days_ago: 5)
    third_receipt = queue(total: 4.55, days_ago: 4)
    first = spend(amount: 4.55, days_ago: 5)
    second = spend(amount: 4.55, days_ago: 4)

    result = run_matcher

    assert_equal 2, result[:matched]
    assert_equal first.entryable, first_receipt.reload.matched_transaction
    assert_equal second.entryable, second_receipt.reload.matched_transaction
    assert third_receipt.reload.waiting?
  end

  test "identical same-day candidates are each used once" do
    receipt_a = queue(total: 3.21, days_ago: 2)
    receipt_b = queue(total: 3.21, days_ago: 2)
    a = spend(amount: 3.21, days_ago: 1)
    b = spend(amount: 3.21, days_ago: 1)

    run_matcher

    assert_equal [ a.entryable, b.entryable ].to_set, [ receipt_a.reload.matched_transaction, receipt_b.reload.matched_transaction ].to_set
  end

  test "candidates that can't be told apart go to a person as ambiguous" do
    receipt = queue(total: 15.55, merchant: "Pret", days_ago: 3)
    spend(amount: 15.55, name: "PRET 1", days_ago: 2)
    spend(amount: 15.55, name: "PRET 2", days_ago: 4)

    run_matcher

    assert receipt.reload.needs_attention?
    assert_equal "ambiguous", receipt.attention_reason
    assert_equal 2, receipt.candidates.size
  end

  test "different transactions with no merchant match are ambiguous, not guessed by date" do
    receipt = queue(total: 18.18, merchant: "Gail's", days_ago: 3)
    spend(amount: 18.18, name: "SHOP ONE", days_ago: 2)
    spend(amount: 18.18, name: "SHOP TWO", days_ago: 3)

    run_matcher

    assert_equal "ambiguous", receipt.reload.attention_reason
  end

  test "a single exact candidate links even when the bank text is unrelated" do
    receipt = queue(total: 61.07, merchant: "Klarna Shop")
    entry = spend(amount: 61.07, name: "KLARNA*PAYMENT")

    run_matcher

    assert_equal entry.entryable, receipt.reload.matched_transaction
  end

  test "a transaction that already holds a receipt is not used again" do
    first = queue(total: 7.77)
    entry = spend(amount: 7.77)
    run_matcher
    second = queue(total: 7.77)

    run_matcher

    assert_equal entry.entryable, first.reload.matched_transaction
    assert second.reload.waiting?
  end

  test "money in and pending transactions are not candidates" do
    receipt = queue(total: 8.88)
    spend(amount: -8.88)
    pending = spend(amount: 8.88)
    pending.entryable.update!(extra: { "plaid" => { "pending" => true } })

    run_matcher

    assert receipt.reload.waiting?
  end

  test "a transaction outside the receipt's window is not a candidate" do
    receipt = queue(total: 9.99, days_ago: 2)
    spend(amount: 9.99, days_ago: 10) # 8 days before the receipt

    run_matcher

    assert receipt.reload.waiting?
  end

  test "a receipt waits up to 14 days, then needs a person with its near misses" do
    waiting = queue(total: 44.44, days_ago: 14, merchant: "Shop")
    stale = queue(total: 55.55, days_ago: 14, merchant: "Gadget Store")
    stale.update_columns(receipt_date: @today - 15)
    spend(amount: 50.01, name: "GADGET STORE LONDON", days_ago: 12)

    result = run_matcher

    assert waiting.reload.waiting?
    assert stale.reload.needs_attention?
    assert_equal "no_transaction_found", stale.attention_reason
    assert_equal 1, stale.candidates.size
    assert_equal "GADGET STORE LONDON", stale.candidates.first["name"]
    assert_equal 1, result[:needs_attention]
    assert_equal 1, result[:waiting]
  end

  test "a Klarna receipt waits 45 days" do
    klarna = queue(total: 33.33, days_ago: 30, klarna: true, merchant: "Shop")
    normal = queue(total: 33.34, days_ago: 30, merchant: "Shop")
    assert klarna.waiting?
    assert normal.archived?, "30 days old on arrival is past the 14-day window"

    normal.requeue!
    run_matcher

    assert klarna.reload.waiting?
    assert normal.reload.needs_attention?

    klarna.update_columns(receipt_date: @today - 46)
    run_matcher

    assert klarna.reload.needs_attention?
  end

  test "a receipt older than its wait window when first queued is archived" do
    old = queue(total: 919.96, days_ago: 3000, merchant: "Carphone Warehouse")
    fresh = queue(total: 5.5, days_ago: 3)

    assert old.archived?
    assert_equal "older_than_wait_window", old.attention_reason
    assert fresh.waiting?

    run_matcher
    assert old.reload.archived?
  end

  test "a requeued archived receipt is matched against newly imported history" do
    old = queue(total: 120.12, days_ago: 100, merchant: "Shop")
    assert old.archived?
    entry = spend(amount: 120.12, name: "SHOP", days_ago: 99)

    old.requeue!
    run_matcher

    assert_equal entry.entryable, old.reload.matched_transaction
  end

  test "the requeue task puts archived receipts back in the queue" do
    RakeTaskTestHelper.prepare("receipts:requeue_archived")
    old = queue(total: 1.1, days_ago: 100)
    fresh = queue(total: 2.2, days_ago: 1)

    capture_io { Rake::Task["receipts:requeue_archived"].invoke }

    assert old.reload.waiting?
    assert fresh.reload.waiting?
  end

  test "a receipt without a total or date needs a person" do
    receipt = queue(total: nil)
    undated, = Receipt.intake!(family: @family, content: "%PDF-1.4 undated", filename: "r.pdf", content_type: "application/pdf", source: :email, total: 5)

    run_matcher

    assert_equal "missing_details", receipt.reload.attention_reason
    assert_equal "missing_details", undated.reload.attention_reason
  end

  test "an excluded account is never matched, by name, id or provider mask" do
    other_account = Account.create!(family: @family, name: "Card 2034", balance: 0, currency: "USD", accountable: CreditCard.new)
    receipt = queue(total: 71.17)
    spend(amount: 71.17, account: other_account)

    run_matcher(excluded_account_ids: Receipt::ExcludedAccounts.new(@family, setting: "card 2034").account_ids)
    assert receipt.reload.waiting?

    run_matcher(excluded_account_ids: Receipt::ExcludedAccounts.new(@family, setting: other_account.id).account_ids)
    assert receipt.reload.waiting?

    plaid_accounts(:one).update!(mask: "2034")
    masked = accounts(:connected)
    spend(amount: 72.27, account: masked)
    receipt_two = queue(total: 72.27)
    ids = Receipt::ExcludedAccounts.new(@family, setting: "2034").account_ids
    assert_includes ids, masked.id

    run_matcher(excluded_account_ids: ids)
    assert receipt_two.reload.waiting?

    run_matcher(excluded_account_ids: [])
    assert receipt.reload.matched?
    assert receipt_two.reload.matched?
  end

  test "the excluded account setting is read from Setting" do
    other_account = Account.create!(family: @family, name: "Card 2034", balance: 0, currency: "USD", accountable: CreditCard.new)
    receipt = queue(total: 81.18)
    spend(amount: 81.18, account: other_account)

    with_receipt_excluded_accounts("Card 2034") { run_matcher }
    assert receipt.reload.waiting?

    run_matcher
    assert receipt.reload.matched?
  end

  test "a transaction at its attachment limit sends the receipt to a person" do
    receipt = queue(total: 91.19)
    spend(amount: 91.19)
    Transaction.any_instance.stubs(:attachments).returns(stub(size: Transaction::MAX_ATTACHMENTS_PER_TRANSACTION))

    run_matcher

    assert_equal "transaction_attachment_limit", receipt.reload.attention_reason
  end

  test "other families' receipts and transactions are left alone" do
    receipt = queue(total: 13.13)
    foreign_account = Account.create!(family: families(:empty), name: "Theirs", balance: 0, currency: "USD", accountable: Depository.new)
    spend(amount: 13.13, account: foreign_account)

    run_matcher

    assert receipt.reload.waiting?
  end

  private

    def with_receipt_excluded_accounts(value)
      previous = Setting.receipt_excluded_accounts
      Setting.receipt_excluded_accounts = value
      yield
    ensure
      Setting.receipt_excluded_accounts = previous
    end
end
