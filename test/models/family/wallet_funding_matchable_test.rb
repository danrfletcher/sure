require "test_helper"

class Family::WalletFundingMatchableTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @bank = accounts(:depository)
    @wallet = @family.accounts.create!(name: "Test Wallet", balance: 0, currency: "USD",
                                      accountable: Depository.new, status: "active")
    @bank.update!(currency: "USD")
    @on = { "WALLET_FUNDING_ACCOUNTS" => "test wallet", "WALLET_FUNDING_BANK_NAMES" => "walletco" }
  end

  def kind_of(entry) = entry.reload.entryable.kind

  test "marks the bank payment neutral when the wallet paid the same amount first" do
    spend = create_transaction(date: 10.days.ago.to_date, account: @wallet, amount: 42.5, name: "Shop")
    bank = create_transaction(date: Date.current, account: @bank, amount: 42.5, name: "WALLETCO PAYMENT")

    with_env_overrides(@on) { assert_equal 1, @family.auto_match_wallet_funding! }

    assert_equal "funds_movement", kind_of(bank)
    assert_equal "standard", kind_of(spend)
  end

  test "does nothing unless a wallet account is configured" do
    create_transaction(date: 5.days.ago.to_date, account: @wallet, amount: 10, name: "Shop")
    bank = create_transaction(date: Date.current, account: @bank, amount: 10, name: "WALLETCO PAYMENT")

    assert_equal 0, @family.auto_match_wallet_funding!
    assert_equal "standard", kind_of(bank)
  end

  test "leaves a bank payment with no wallet row alone" do
    bank = create_transaction(date: Date.current, account: @bank, amount: 77, name: "WALLETCO PAYMENT")

    with_env_overrides(@on) { assert_equal 0, @family.auto_match_wallet_funding! }

    assert_equal "standard", kind_of(bank)
  end

  test "ignores a wallet row dated after the bank payment" do
    create_transaction(date: Date.current, account: @wallet, amount: 20, name: "Shop")
    bank = create_transaction(date: 3.days.ago.to_date, account: @bank, amount: 20, name: "WALLETCO PAYMENT")

    with_env_overrides(@on) { assert_equal 0, @family.auto_match_wallet_funding! }

    assert_equal "standard", kind_of(bank)
  end

  test "ignores a wallet row older than the window" do
    create_transaction(date: 40.days.ago.to_date, account: @wallet, amount: 20, name: "Shop")
    bank = create_transaction(date: Date.current, account: @bank, amount: 20, name: "WALLETCO PAYMENT")

    with_env_overrides(@on) { assert_equal 0, @family.auto_match_wallet_funding! }
    assert_equal "standard", kind_of(bank)

    with_env_overrides(@on.merge("WALLET_FUNDING_DAYS" => "45")) { assert_equal 1, @family.auto_match_wallet_funding! }
    assert_equal "funds_movement", kind_of(bank)
  end

  test "uses each wallet row only once" do
    create_transaction(date: 5.days.ago.to_date, account: @wallet, amount: 15, name: "Shop")
    first = create_transaction(date: 2.days.ago.to_date, account: @bank, amount: 15, name: "WALLETCO PAYMENT")
    second = create_transaction(date: Date.current, account: @bank, amount: 15, name: "WALLETCO PAYMENT")

    with_env_overrides(@on) { assert_equal 1, @family.auto_match_wallet_funding! }
    with_env_overrides(@on) { assert_equal 0, @family.auto_match_wallet_funding! }

    assert_equal "funds_movement", kind_of(first)
    assert_equal "standard", kind_of(second)
  end

  test "does not match across currencies or names" do
    create_transaction(date: 5.days.ago.to_date, account: @wallet, amount: 30, name: "Shop")
    other_name = create_transaction(date: Date.current, account: @bank, amount: 30, name: "Corner Shop")

    with_env_overrides(@on) { assert_equal 0, @family.auto_match_wallet_funding! }

    assert_equal "standard", kind_of(other_name)
  end

  test "pairs a foreign-currency wallet row with a bank payment inside the tolerance" do
    ExchangeRate.stubs(:find_or_fetch_rate).returns(stub(rate: 0.8))
    spend = create_transaction(date: 4.days.ago.to_date, account: @wallet, amount: 100, name: "Shop", currency: "EUR")
    bank = create_transaction(date: Date.current, account: @bank, amount: 81.5, name: "WALLETCO PAYMENT")

    with_env_overrides(@on) { assert_equal 1, @family.auto_match_wallet_funding! }

    assert_equal "funds_movement", kind_of(bank)
    assert_equal "standard", kind_of(spend)
  end

  test "leaves a converted match alone when it is outside the tolerance" do
    ExchangeRate.stubs(:find_or_fetch_rate).returns(stub(rate: 0.8))
    create_transaction(date: 4.days.ago.to_date, account: @wallet, amount: 100, name: "Shop", currency: "EUR")
    bank = create_transaction(date: Date.current, account: @bank, amount: 90, name: "WALLETCO PAYMENT")

    with_env_overrides(@on) { assert_equal 0, @family.auto_match_wallet_funding! }

    assert_equal "standard", kind_of(bank)
  end

  test "leaves a converted match alone when two wallet rows fit" do
    ExchangeRate.stubs(:find_or_fetch_rate).returns(stub(rate: 0.8))
    create_transaction(date: 4.days.ago.to_date, account: @wallet, amount: 100, name: "Shop A", currency: "EUR")
    create_transaction(date: 3.days.ago.to_date, account: @wallet, amount: 101, name: "Shop B", currency: "EUR")
    bank = create_transaction(date: Date.current, account: @bank, amount: 81, name: "WALLETCO PAYMENT")

    with_env_overrides(@on) { assert_equal 0, @family.auto_match_wallet_funding! }

    assert_equal "standard", kind_of(bank)
  end

  test "dry run reports pairs without changing anything" do
    create_transaction(date: 5.days.ago.to_date, account: @wallet, amount: 12, name: "Shop")
    bank = create_transaction(date: Date.current, account: @bank, amount: 12, name: "WALLETCO PAYMENT")

    pairs = with_env_overrides(@on) { @family.auto_match_wallet_funding!(dry_run: true) }

    assert_equal 1, pairs.size
    assert_equal "standard", kind_of(bank)
  end
end
