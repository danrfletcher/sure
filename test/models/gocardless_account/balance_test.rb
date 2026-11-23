# frozen_string_literal: true

require "test_helper"

class GocardlessAccount::BalanceTest < ActiveSupport::TestCase
  setup do
    item = families(:empty).gocardless_items.create!(
      name: "Lloyds", secret_id: "id", secret_key: "key",
      requisition_id: "req-card", institution_id: "LLOYDS_LOYDGB2L"
    )
    @account = item.gocardless_accounts.create!(gocardless_account_id: "acc-1", name: "Card", currency: "GBP")
    @balances = [
      { balanceType: "interimAvailable", balanceAmount: { amount: "3500.00", currency: "GBP" } },
      { balanceType: "interimBooked", balanceAmount: { amount: "-120.50", currency: "GBP" } }
    ]
  end

  test "a card's balance is the booked figure, not the unused credit limit" do
    @account.account_type = "CARD"
    assert_equal BigDecimal("-120.50"), @account.pick_balance(@balances)
  end

  test "other accounts still prefer the available balance" do
    @account.account_type = "CACC"
    assert_equal BigDecimal("3500.00"), @account.pick_balance(@balances)
  end
end
