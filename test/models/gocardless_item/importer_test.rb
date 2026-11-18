# frozen_string_literal: true

require "test_helper"

class GocardlessItem::ImporterTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @item = @family.gocardless_items.create!(
      name: "Monzo", secret_id: "id", secret_key: "key",
      requisition_id: "req-1", institution_id: "MONZO_MONZGB2L"
    )
    @provider = mock("provider")
    @sure_account = @family.accounts.create!(
      name: "Monzo", balance: 0, currency: "GBP", accountable: Depository.new
    )
  end

  def booked(id, amount, date: "2026-11-10", creditor: nil, debtor: nil)
    {
      transactionId: id, bookingDate: date,
      transactionAmount: { amount: amount, currency: "GBP" },
      creditorName: creditor, debtorName: debtor,
      remittanceInformationUnstructured: "ref #{id}"
    }.compact
  end

  def stub_linked_requisition(account_ids = [ "acc-1" ])
    @provider.stubs(:requisition).with("req-1").returns(status: "LN", accounts: account_ids)
    @provider.stubs(:account_details).returns(account: { name: "Current", currency: "GBP", cashAccountType: "CACC" })
    @provider.stubs(:account_balances).returns(balances: [ { balanceType: "interimAvailable", balanceAmount: { amount: "12.50", currency: "GBP" } } ])
  end

  def import!
    GocardlessItem::Importer.new(@item, gocardless_provider: @provider).import
  end

  test "creates accounts from the requisition and keeps the bank's name" do
    stub_linked_requisition
    import!

    account = @item.gocardless_accounts.find_by!(gocardless_account_id: "acc-1")
    assert_equal "Current", account.name
    assert_equal "GBP", account.currency
    assert_equal BigDecimal("12.50"), account.current_balance
  end

  test "imports booked transactions, flips the sign and is idempotent" do
    stub_linked_requisition
    import!
    account = @item.gocardless_accounts.first
    account.ensure_account_provider!(@sure_account)

    @provider.stubs(:account_transactions).returns(
      transactions: {
        booked: [ booked("t1", "-4.20", creditor: "Pret"), booked("t2", "100.00", debtor: "Employer") ],
        pending: [ booked("p1", "-1.00") ]
      }
    )

    2.times do
      account.update_columns(last_pulled_at: nil)
      import!
      GocardlessAccount::Processor.new(account.reload).process
    end

    entries = @sure_account.entries.where(entryable_type: "Transaction").order(:name)
    assert_equal 2, entries.count, "pending skipped, re-import adds no duplicates"
    pret = entries.find_by!(name: "Pret")
    assert_equal BigDecimal("4.20"), pret.amount, "money out is positive in Sure"
    assert_equal BigDecimal("-100.00"), entries.find_by!(name: "Employer").amount
  end

  test "an account pulled within six hours is not pulled again" do
    stub_linked_requisition
    import!
    account = @item.gocardless_accounts.first
    account.ensure_account_provider!(@sure_account)
    account.update_columns(last_pulled_at: 1.hour.ago)

    @provider.expects(:account_transactions).never
    import!
  end

  test "a first pull asks for the full history window, later pulls overlap by a week" do
    stub_linked_requisition
    import!
    account = @item.gocardless_accounts.first
    account.ensure_account_provider!(@sure_account)

    @provider.expects(:account_transactions).with("acc-1", date_from: 730.days.ago.to_date, date_to: Date.current).returns(transactions: { booked: [] })
    import!

    last = 8.hours.ago
    account.reload.update_columns(last_pulled_at: last)
    @provider.expects(:account_transactions).with("acc-1", date_from: (last - 7.days).to_date, date_to: Date.current).returns(transactions: { booked: [] })
    import!
  end

  test "an expired consent marks the item for re-linking and stops" do
    @provider.stubs(:requisition).returns(status: "EX", accounts: [])

    assert_raises(Provider::Gocardless::ConsentExpiredError) { import! }
    assert @item.reload.requires_update?
  end

  test "writes raw responses to the backup directory when configured" do
    Dir.mktmpdir do |dir|
      ENV["GOCARDLESS_RAW_DIR"] = dir
      stub_linked_requisition
      import!
      account = @item.gocardless_accounts.first
      account.ensure_account_provider!(@sure_account)
      @provider.stubs(:account_transactions).returns(transactions: { booked: [ booked("t1", "-1.00") ] })
      import!

      path = File.join(dir, "req-1", "acc-1.transactions.json")
      assert File.exist?(path)
      assert_equal "600", format("%o", File.stat(path).mode & 0o777)
    ensure
      ENV.delete("GOCARDLESS_RAW_DIR")
    end
  end
end
