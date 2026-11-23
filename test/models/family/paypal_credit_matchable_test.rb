require "test_helper"

class Family::PaypalCreditMatchableTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @wallet = @family.accounts.create!(name: "Test Wallet", balance: 0, currency: "GBP", accountable: Depository.new, status: "active")
    @card = @family.accounts.create!(name: "Test Credit", balance: 0, currency: "GBP", accountable: CreditCard.new, status: "active")
    @payment = create_transaction(date: Date.parse("2025-08-28"), account: @wallet, amount: 250, name: "Outgoing Transfer")
    @env = { "PAY_IN_3_ACCOUNT" => @wallet.id, "PAYPAL_CREDIT_CARD" => @card.id }
  end

  def rows_stub = [ { id: "x1", entry: @payment, date: @payment.date, amount: 250.0, currency: "GBP", dir: "DBIT", code: "PAYPAL_CREDIT_PAYMENT" } ]

  test "links a credit repayment to the card as a transfer and is idempotent" do
    @family.stubs(:pay_in_3_rows).returns(rows_stub)

    with_env_overrides(@env) do
      assert_equal 1, @family.auto_match_paypal_credit!
      assert_equal 0, @family.auto_match_paypal_credit!
    end

    assert_equal "cc_payment", @payment.reload.entryable.kind
    assert_equal [ -250.0 ], @card.entries.where(source: "paypal_credit").pluck(:amount).map(&:to_f)
  end

  test "does nothing unless the card exists and is configured" do
    @family.stubs(:pay_in_3_rows).returns(rows_stub)

    assert_equal 0, @family.auto_match_paypal_credit!
    with_env_overrides(@env.merge("PAYPAL_CREDIT_CARD" => "Test Credit")) { assert_equal 0, @family.auto_match_paypal_credit! }
    assert_equal "standard", @payment.reload.entryable.kind
  end
end
