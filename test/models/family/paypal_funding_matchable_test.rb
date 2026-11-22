require "test_helper"

class Family::PaypalFundingMatchableTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @wallet = @family.accounts.create!(name: "Test Wallet", balance: 0, currency: "GBP", accountable: Depository.new, status: "active")
    @bank = @family.accounts.create!(name: "Test Bank", balance: 0, currency: "GBP", accountable: Depository.new, status: "active")
    @amex = @family.accounts.create!(name: "Test Amex", balance: 0, currency: "GBP", accountable: CreditCard.new, status: "active")
    @card = @family.accounts.create!(name: "Test PayPal Credit", balance: 0, currency: "GBP", accountable: CreditCard.new, status: "active")
    @env = { "PAY_IN_3_ACCOUNT" => @wallet.id, "PAYPAL_CREDIT_CARD" => @card.id, "WALLET_FUNDING_ACCOUNTS" => @wallet.id,
             "WALLET_FUNDING_BANK_NAMES" => "paypal" }
    @family.stubs(:pay_in_3_rows).returns([])
    @family.stubs(:auto_match_pay_in_3!)
  end

  def gbp_tx(**attrs) = create_transaction(currency: "GBP", **attrs)
  def run_match = with_env_overrides(@env) { @family.auto_match_paypal_funding! }
  def card_amounts = @card.entries.where(source: "paypal_funding").order(:date, :amount).pluck(:amount).map(&:to_f)

  test "a card charge marked PAYPAL * funds the wallet payment and the wallet row keeps the spending" do
    spend = gbp_tx(date: 20.days.ago.to_date, account: @wallet, amount: 100, name: "eBay")
    charge = gbp_tx(date: 20.days.ago.to_date, account: @amex, amount: 100, name: "EBAY", category: categories(:food_and_drink))
    charge.entryable.update!(extra: { "gocardless" => { "description" => "PAYPAL *EBAY 4029357733" } })

    run_match

    assert_equal "funds_movement", charge.reload.entryable.kind
    assert_equal "standard", spend.reload.entryable.kind
    assert_equal categories(:food_and_drink), spend.entryable.category
    assert_empty card_amounts
  end

  test "the transfer guesser never pairs the matcher's own card rows" do
    spend = gbp_tx(date: 20.days.ago.to_date, account: @wallet, amount: 73.01, name: "Battery")
    gbp_tx(date: 16.days.ago.to_date, account: @bank, amount: 73.01, name: "PAYPAL PAYMENT")
    run_match
    other = @family.accounts.create!(name: "Other Bank", balance: 0, currency: "GBP", accountable: Depository.new, status: "active")
    top_up_out = gbp_tx(date: spend.date, account: other, amount: 73.01, name: "To own account")
    top_up_in = gbp_tx(date: spend.date, account: @bank, amount: -73.01, name: "From own account")

    card_ids = @card.entries.pluck(:entryable_id)
    pairs = @family.transfer_match_candidates.map { |c| [ c.outflow_transaction_id, c.inflow_transaction_id ] }
    assert pairs.flatten.none? { |id| card_ids.include?(id) }
    assert_includes pairs, [ top_up_out.entryable_id, top_up_in.entryable_id ]
  end

  test "an unmarked card charge needs pence to match, and only one candidate" do
    odd = gbp_tx(date: 20.days.ago.to_date, account: @wallet, amount: 41.73, name: "Adam Atwater")
    odd_charge = gbp_tx(date: 20.days.ago.to_date, account: @bank, amount: 41.73, name: "Atcorepair")
    gbp_tx(date: 20.days.ago.to_date, account: @wallet, amount: 50, name: "Shop")
    round_charge = gbp_tx(date: 20.days.ago.to_date, account: @bank, amount: 50, name: "Tesco")

    run_match

    assert_equal "funds_movement", odd_charge.reload.entryable.kind
    assert_equal odd.id.to_s, odd_charge.entryable.extra["wallet_funding_entry_id"]
    assert_equal "standard", round_charge.reload.entryable.kind
  end

  test "a bank-funded payment is owed on the card from the purchase day until the bank pays" do
    spend = gbp_tx(date: 20.days.ago.to_date, account: @wallet, amount: 25.5, name: "Shop")
    bank = gbp_tx(date: 16.days.ago.to_date, account: @bank, amount: 25.5, name: "PAYPAL PAYMENT")

    run_match
    run_match

    assert_equal "cc_payment", bank.reload.entryable.kind
    assert_equal "standard", spend.reload.entryable.kind
    assert_equal [ 25.5, -25.5 ], card_amounts
    assert_equal [ spend.date, bank.date ], @card.entries.where(source: "paypal_funding").order(:date).pluck(:date)
  end

  test "a bank payment smaller by money PayPal returned earlier settles the rest" do
    gbp_tx(date: 40.days.ago.to_date, account: @wallet, amount: -14.0, name: "Refund")
    spend = gbp_tx(date: 20.days.ago.to_date, account: @wallet, amount: 14.2, name: "SHEIN")
    bank = gbp_tx(date: 17.days.ago.to_date, account: @bank, amount: 0.2, name: "PAYPAL PAYMENT")

    run_match

    assert_equal spend.id.to_s, bank.reload.entryable.extra["wallet_funding_entry_id"]
    assert_equal [ 0.2, -0.2 ], card_amounts
  end

  test "a withdrawal becomes a transfer to the bank" do
    out = gbp_tx(date: 20.days.ago.to_date, account: @wallet, amount: 81.54, name: "Outgoing Transfer")
    inflow = gbp_tx(date: 19.days.ago.to_date, account: @bank, amount: -81.54, name: "Payment from Paypal")
    @family.stubs(:pay_in_3_rows).returns([ { id: "w", entry: out, date: out.date, amount: 81.54, currency: "GBP", dir: "DBIT", code: "MONEY_TRANSFER" } ])

    run_match

    assert_equal "funds_movement", out.reload.entryable.kind
    assert_equal out.entryable, inflow.reload.entryable.transfer.outflow_transaction
  end

  test "an unmatched recent payment is owed provisionally, then dropped after the wait" do
    spend = gbp_tx(date: 2.days.ago.to_date, account: @wallet, amount: 9.99, name: "Shop")

    run_match
    assert_equal [ 9.99 ], card_amounts

    spend.update!(date: 30.days.ago.to_date)
    run_match
    assert_empty card_amounts
    assert_equal "standard", spend.reload.entryable.kind
  end

  test "a provisional charge becomes the real one when the bank pays" do
    spend = gbp_tx(date: 3.days.ago.to_date, account: @wallet, amount: 12, name: "Shop")
    run_match
    bank = gbp_tx(date: Date.current, account: @bank, amount: 12, name: "PAYPAL PAYMENT")
    run_match

    assert_equal [ 12.0, -12.0 ], card_amounts
    assert_nil @card.entries.find_by(external_id: "paypal_funding:charge:#{spend.id}").entryable.extra["provisional"]
    assert_equal "cc_payment", bank.reload.entryable.kind
  end

  test "excluded rows and accounts named instead of by id are ignored" do
    spend = gbp_tx(date: 2.days.ago.to_date, account: @wallet, amount: 45.99, name: "Ryanair")
    spend.update!(excluded: true)
    run_match
    assert_empty card_amounts

    gbp_tx(date: 2.days.ago.to_date, account: @wallet, amount: 5.5, name: "Shop")
    with_env_overrides(@env.merge("PAY_IN_3_ACCOUNT" => "Test Wallet", "PAYPAL_CREDIT_CARD" => "Test PayPal Credit")) { @family.auto_match_paypal_funding! }
    assert_empty card_amounts
  end
end
