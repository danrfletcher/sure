require "test_helper"

class Family::PayInThreeMatchableTest < ActiveSupport::TestCase
  include EntriesTestHelper

  def row(id, date, amount, code, dir = "DBIT", merchant = "shop")
    { id: id, date: Date.parse(date), amount: amount, currency: "GBP", dir: dir, code: code, merchant: merchant }
  end

  test "pairs a purchase with its three instalments and settles it" do
    rows = [ row("p", "2026-01-10", 30.99, "PAYMENT"), row("a", "2026-01-10", 10.33, "LOAN"),
             row("b", "2026-02-10", 10.33, "LOAN"), row("c", "2026-03-10", 10.33, "LOAN") ]
    result = Family::PayIn3Matchable.plan(rows)

    assert_equal 1, result[:plans].size
    assert_equal 0.0, result[:plans].first[:owed]
    assert_empty result[:parked]
  end

  test "an open plan with an instalment still to come keeps its balance" do
    rows = [ row("p", "2026-01-10", 30.99, "PAYMENT"), row("a", "2026-01-10", 10.33, "LOAN"), row("b", "2026-02-10", 10.33, "LOAN") ]
    result = Family::PayIn3Matchable.plan(rows)

    assert_equal 10.33, result[:plans].first[:owed]
  end

  test "a loan debit with no purchase is parked and never claimed" do
    result = Family::PayIn3Matchable.plan([ row("x", "2026-01-10", 12.34, "LOAN") ])

    assert_empty result[:plans]
    assert_equal [ "x" ], result[:parked].map { |l| l[:id] }
  end

  test "an unexplained checkout gap stays out of the card" do
    rows = [ row("p1", "2026-01-10", 30.00, "PAYMENT", "DBIT", "ebay"), row("p2", "2026-01-10", 15.00, "PAYMENT", "DBIT", "ebay"),
             row("a", "2026-01-10", 10.00, "LOAN"), row("b", "2026-01-10", 5.00, "LOAN") ]
    result = Family::PayIn3Matchable.plan(rows)

    assert_empty result[:plans]
    assert_equal 1, result[:unresolved].size
  end

  test "apply charges the card, links each instalment and is idempotent" do
    family = families(:dylan_family)
    wallet = family.accounts.create!(name: "Test Wallet", balance: 0, currency: "GBP", accountable: Depository.new, status: "active")
    purchase = create_transaction(date: Date.parse("2026-01-10"), account: wallet, amount: 30.99, name: "Shop")
    first = create_transaction(date: Date.parse("2026-01-10"), account: wallet, amount: 10.33, name: "554 PayPal UK")
    second = create_transaction(date: Date.parse("2026-02-10"), account: wallet, amount: 10.33, name: "554 PayPal UK")
    plan = { date: purchase.date, merchant: "shop", purchases: [ { id: "p", entry: purchase } ], charge: 30.99, credits: [],
             instalments: [ { id: "a", date: first.date, amount: 10.33, entry: first }, { id: "b", date: second.date, amount: 10.33, entry: second } ] }

    assert_equal 1, Family::PayIn3Matchable.apply(family, wallet, "Test Pay in 3", [ plan ])
    assert_equal 0, Family::PayIn3Matchable.apply(family, wallet, "Test Pay in 3", [ plan ])

    card = family.accounts.find_by!(name: "Test Pay in 3")
    assert card.credit_card?
    assert_equal [ -10.33, -10.33, 30.99 ], card.entries.where(source: "pay_in_3").pluck(:amount).map(&:to_f).sort
    assert_equal "cc_payment", first.reload.entryable.kind
    assert_equal "standard", purchase.reload.entryable.kind
  end
end
