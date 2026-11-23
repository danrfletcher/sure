require "test_helper"

class Family::KlarnaFeedMatchableTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @bank = @family.accounts.create!(name: "Test Bank", balance: 0, currency: "GBP", accountable: Depository.new, status: "active")
    @p3 = @family.accounts.create!(name: "Test P3", balance: 0, currency: "GBP", accountable: CreditCard.new, status: "active")
    @credit = @family.accounts.create!(name: "Test Credit", balance: 0, currency: "GBP", accountable: CreditCard.new, status: "active")
    @env = { "KLARNA_PAY_IN_3_CARD" => @p3.id, "KLARNA_CREDIT_CARD" => @credit.id, "KLARNA_BANK_ACCOUNTS" => @bank.id }
    @food = categories(:food_and_drink)
  end

  def bank_row(date, amount, name = "KLARNA*SHOPCO", category: @food)
    create_transaction(date: Date.parse(date), account: @bank, amount: amount, currency: "GBP", name: name, category: category)
  end

  def plan(payments:, adjustments: [], refunds: [], total: 90)
    { key: "ABC123", merchant: "Shopco", order_date: "2026-10-01", total: total, status: "open",
      payments: payments, adjustments: adjustments, refunds: refunds }
  end

  def import!(feed, **opts)
    with_env_overrides(@env) { @family.import_klarna_feed!(feed, today: Date.parse("2026-11-20"), **opts) }
  end

  test "books a Pay in 3 purchase in full and links each instalment as a card payment" do
    r1 = bank_row("2026-10-02", 30)
    r2 = bank_row("2026-11-01", 30)
    feed = { pay_in_3: [ plan(payments: [ { id: "p1", date: "2026-10-01", amount: 30 }, { id: "p2", date: "2026-11-01", amount: 30 } ]) ] }

    report = import!(feed)
    assert_equal 1, report[:booked].size
    assert_equal 2, report[:linked].size

    purchase = @p3.entries.find_by(external_id: "klarna:ABC123:purchase")
    assert_equal 90, purchase.amount
    assert_equal @food, purchase.entryable.category
    [ r1, r2 ].each do |r|
      t = r.reload.entryable
      assert_equal "cc_payment", t.kind
      assert_nil t.category_id
      assert t.transfer_as_outflow.present?
    end
    assert_equal [ -30, -30 ], @p3.entries.where(external_id: [ "klarna:ABC123:pay:p1", "klarna:ABC123:pay:p2" ]).pluck(:amount).map(&:to_i)

    second = import!(feed)
    assert_empty second[:booked]
    assert_empty second[:linked]
  end

  test "a return reduces what is owed, and a cancelled order is refunded in full with the money back linked" do
    bank_row("2026-10-02", 30)
    back = bank_row("2026-11-15", -30, "KLARNA REFUND", category: nil)
    feed = { pay_in_3: [ plan(payments: [ { id: "p1", date: "2026-10-01", amount: 30 } ],
                              adjustments: [ { id: "a1", date: "2026-10-05", amount: 6 } ],
                              refunds: [ { id: "r1", date: "2026-11-14", amount: 30, cancels_order: true } ]) ] }

    import!(feed)
    assert_equal(-6, @p3.entries.find_by(external_id: "klarna:ABC123:adjust:a1").amount)
    assert_equal(-84, @p3.entries.find_by(external_id: "klarna:ABC123:refund:r1").amount)
    assert_equal "funds_movement", back.reload.entryable.kind
    assert back.entryable.transfer_as_inflow.present?
    # card: +90 purchase, -30 payment, -6 return, -84 cancelled, +30 money back = 0
    assert_equal 0, @p3.entries.sum(:amount)
  end

  test "waits for a recent payment the bank has not shown, then warns once it is late" do
    feed = { pay_in_3: [ plan(payments: [ { id: "p1", date: "2026-11-19", amount: 30 } ]) ] }
    report = import!(feed)
    assert_equal 1, report[:waiting].size
    assert_empty report[:warnings]

    late = { pay_in_3: [ plan(payments: [ { id: "p1", date: "2026-11-01", amount: 30 } ]) ] }
    assert_equal 1, import!(late)[:warnings].size
  end

  test "a bank row is only linked once even when two payments share an amount" do
    bank_row("2026-10-02", 30)
    feed = { pay_in_3: [ plan(payments: [ { id: "p1", date: "2026-10-01", amount: 30 }, { id: "p2", date: "2026-10-02", amount: 30 } ]) ] }
    report = import!(feed)
    assert_equal 1, report[:linked].size
    assert_equal 1, report[:waiting].size + report[:warnings].size
  end

  test "books one uncategorised charge per credit statement and links its payment" do
    row = bank_row("2026-07-02", 222.71, "Klarna* Klarna")
    feed = { credit_card: [
      { key: "2026-06-16", start: "2026-05-17", end: "2026-06-16", balance: 222.71, charges: 222.71, payments: [ { id: "s1", date: "2026-07-02", amount: 222.71 } ] },
      { key: "2026-07-16", start: "2026-06-17", end: "2026-07-16", balance: 0, charges: 0, payments: [] }
    ] }

    import!(feed)
    charge = @credit.entries.find_by(external_id: "klarna_credit:2026-06-16:charges")
    assert_equal 222.71, charge.amount.to_f
    assert_equal Date.parse("2026-06-16"), charge.date
    assert_nil charge.entryable.category_id
    assert_equal "cc_payment", row.reload.entryable.kind
    assert_equal 0, @credit.entries.sum(:amount)
  end

  test "dry run writes nothing, and nothing happens unless configured by id" do
    row = bank_row("2026-10-02", 30)
    feed = { pay_in_3: [ plan(payments: [ { id: "p1", date: "2026-10-01", amount: 30 } ]) ] }

    report = import!(feed, dry_run: true)
    assert_equal 1, report[:booked].size
    assert_equal 0, @p3.entries.count
    assert_equal "standard", row.reload.entryable.kind

    with_env_overrides(@env.merge("KLARNA_PAY_IN_3_CARD" => "Test P3", "KLARNA_CREDIT_CARD" => "")) do
      assert_equal [ "Klarna is not configured" ], @family.import_klarna_feed!(feed)[:warnings]
    end
  end
end
