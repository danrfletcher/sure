require "test_helper"

class IncomeStatement::FundingSankeyTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @month = Date.new(2024, 2, 1)
    @checking = account("Checking", Depository.new)
    @savings = account("Savings account", Depository.new(subtype: "savings"))
    @wallet = account("Wallet", Depository.new)
    @card = account("Card", CreditCard.new)
    @loan = account("Loan", Loan.new)
    @brokerage = account("Brokerage", Investment.new)
    @salary = category("Salary")
    @interest = category("Interest")
    @gift = category("Gift")
    @sale = category("Sale")
    @shopping = category("Shopping")
    @groceries = category("Groceries", parent: @shopping)
    @savings_marker = category("Savings")
    @loans = category("Loan Repayments")
    @interest_paid = category("Interest Payments", parent: @loans)
    @env = { "FUNDING_RETURNS_CATEGORIES" => @interest.id, "FUNDING_RECEIVED_CATEGORIES" => @gift.id,
             "FUNDING_ASSET_SALES_CATEGORIES" => @sale.id, "FUNDING_SAVINGS_CATEGORIES" => @savings_marker.id,
             "FUNDING_LOAN_REPAYMENTS_CATEGORY" => @loans.id }
  end

  test "income categories feed their families, and a fall in current accounts shows as Cash" do
    transaction(@checking, -1000, @salary)
    transaction(@checking, -20, @interest)
    transaction(@checking, -50, @gift)
    transaction(@checking, 1300, @groceries)
    result = graph

    assert_equal "net_by_funding", result[:basis]
    assert_equal "1070.0", result[:income]
    assert_equal "1300.0", result[:spending]
    assert_link result, "income_sub_#{@salary.id}", "funding_income", "1000.0"
    assert_link result, "funding_investment_returns", "cash_flow_node", "20.0"
    assert_link result, "funding_monies_received", "cash_flow_node", "50.0"
    assert_link result, "funding_cash", "cash_flow_node", "230.0"
    assert_link result, "expense_#{@shopping.id}", "expense_sub_#{@groceries.id}", "1300.0"
    assert_nil node(result, "deficit_node")
    assert_nil node(result, "funding_unreconciled")
    assert_balanced result
  end

  test "a rise in current accounts is Increase in Cash on Hand, and refunds net against their category" do
    transaction(@checking, -1000, @salary)
    transaction(@checking, 100, @shopping)
    transaction(@checking, -30, @shopping)
    result = graph

    assert_link result, "cash_flow_node", "expense_#{@shopping.id}", "70.0"
    assert_link result, "cash_flow_node", "funding_use_cash_on_hand", "930.0"
    assert_balanced result
  end

  test "card spending is Borrowing, and card debt paid down is Loan Repayments with interest beside it" do
    transaction(@card, 200, @shopping)
    assert_link graph, "funding_borrowing", "cash_flow_node", "200.0"
    assert_link graph, "funding_sub_borrowing_credit_cards", "funding_borrowing", "200.0"

    transaction(@checking, -1000, @salary)
    transaction(@card, 10, @interest_paid)
    create_transfer(from_account: @checking, to_account: @card, amount: 300, date: @month + 5)
    result = graph

    assert_nil node(result, "funding_borrowing"), "card debt nets to one side"
    assert_link result, "cash_flow_node", "expense_#{@loans.id}", "100.0"
    assert_link result, "expense_#{@loans.id}", "funding_sub_credit_card_principal", "90.0"
    assert_link result, "expense_#{@loans.id}", "expense_sub_#{@interest_paid.id}", "10.0"
    assert_link result, "cash_flow_node", "funding_use_cash_on_hand", "700.0"
    assert_balanced result
  end

  test "each kind of borrowing nets only against itself: a loan that pays off the cards shows on both sides" do
    transaction(@checking, -1000, @salary)
    transaction(@card, 300, @shopping)
    create_transfer(from_account: @loan, to_account: @card, amount: 1000, date: @month + 2)
    result = graph

    assert_link result, "funding_borrowing", "cash_flow_node", "1000.0"
    assert_link result, "funding_sub_borrowing_loans", "funding_borrowing", "1000.0"
    assert_nil node(result, "funding_sub_borrowing_credit_cards")
    assert_link result, "expense_#{@loans.id}", "funding_sub_credit_card_principal", "700.0"
    assert_balanced result
  end

  test "a loan payment to a loan on the chart is Loan Principal, not spending" do
    transaction(@checking, -1000, @salary)
    payment = create_transfer(from_account: @checking, to_account: @loan, amount: 250, date: @month + 4)
    payment.outflow_transaction.update!(kind: "loan_payment", category: @shopping)
    result = graph

    assert_link result, "expense_#{@loans.id}", "funding_sub_loan_principal", "250.0"
    assert_nil node(result, "expense_#{@shopping.id}")
    assert_link result, "cash_flow_node", "funding_use_cash_on_hand", "750.0"
    assert_balanced result
  end

  test "FUNDING_DATA_FROM clamps the period start and says so" do
    create_transaction(account: @checking, amount: 70, category: @shopping, date: @month + 3)
    create_transaction(account: @checking, amount: 30, category: @shopping, date: @month + 20)
    @env = @env.merge("FUNDING_DATA_FROM" => (@month + 10).iso8601)
    result = graph

    assert_equal @month + 10, result[:data_from]
    assert_link result, "cash_flow_node", "expense_#{@shopping.id}", "30.0"
    assert_balanced result

    period = Period.custom(start_date: @month + 10, end_date: @month.end_of_month)
    assert_nil IncomeStatement::FundingSankey.new(IncomeStatement.new(@family), period: period, env: @env).as_json[:data_from], "no note when nothing was cut"

    period = Period.custom(start_date: @month - 60, end_date: @month + 5)
    assert_empty IncomeStatement::FundingSankey.new(IncomeStatement.new(@family), period: period, env: @env).as_json[:links], "a period wholly before the date is empty"
  end

  test "with no Loan Repayments category, interest nests beside the principal" do
    interest_paid = category("Card Interest")
    @env = @env.except("FUNDING_LOAN_REPAYMENTS_CATEGORY").merge("FUNDING_INTEREST_CATEGORY" => interest_paid.id)
    transaction(@checking, -1000, @salary)
    transaction(@card, 5, interest_paid)
    create_transfer(from_account: @checking, to_account: @card, amount: 105, date: @month + 5)
    result = graph

    assert_link result, "cash_flow_node", "funding_loan_repayments", "105.0"
    assert_link result, "funding_loan_repayments", "funding_sub_credit_card_principal", "100.0"
    assert_link result, "funding_loan_repayments", "expense_#{interest_paid.id}", "5.0"
    assert_balanced result
  end

  test "savings moves net to one side, including a savings place that is not an account" do
    transaction(@checking, -1000, @salary)
    transaction(@checking, 600, @shopping)
    create_transfer(from_account: @checking, to_account: @savings, amount: 300, date: @month + 3)
    transaction(@checking, 100, @savings_marker)
    result = graph

    assert_link result, "cash_flow_node", "funding_use_savings", "400.0"
    assert_nil node(result, "expense_#{@savings_marker.id}"), "a savings move is never spending"
    assert_equal "600.0", result[:spending]

    create_transfer(from_account: @savings, to_account: @checking, amount: 900, date: @month + 9)
    assert_link graph, "funding_withdrawals_from_savings", "cash_flow_node", "500.0"
  end

  test "what stays inside an investment account is neutral, and cash arriving from it is an Asset Sale" do
    transaction(@brokerage, 3, @shopping)
    transaction(@brokerage, -1, @interest)
    create_transfer(from_account: @brokerage, to_account: @checking, amount: 500, date: @month + 2)
    transaction(@checking, -14_500, @sale)
    result = graph

    assert_nil node(result, "expense_#{@shopping.id}")
    assert_link result, "funding_asset_sales", "cash_flow_node", "15000.0"
    assert_link result, "cash_flow_node", "funding_use_cash_on_hand", "15000.0"
    assert_balanced result
  end

  test "contributions into an investment account show once, under their category" do
    contributions = category("Investment Contributions")
    transaction(@checking, -1000, @salary)
    create_transaction(account: @checking, amount: 250, category: contributions, date: @month, kind: "investment_contribution")
    result = graph

    assert_link result, "cash_flow_node", "expense_#{contributions.id}", "250.0"
    assert_link result, "cash_flow_node", "funding_use_cash_on_hand", "750.0"
  end

  test "a one-sided transfer row is neutral" do
    transaction(@checking, -1000, @salary)
    transaction(@checking, 400, @shopping)
    create_transaction(account: @checking, amount: 5000, category: nil, date: @month, kind: "funds_movement")
    result = graph

    assert_link result, "cash_flow_node", "funding_use_cash_on_hand", "600.0"
    assert_nil node(result, "funding_unreconciled")
  end

  test "a wallet payment charged to a card counts as Borrowing: who paid is the last hop" do
    purchase = transaction(@wallet, 100, @shopping)
    transaction(@wallet, -100, nil, kind: "funds_movement")
    create_transaction(account: @card, amount: 100, category: nil, date: @month, kind: "funds_movement",
                       currency: "USD").entryable.update!(extra: { "wallet_funding_entry_id" => purchase.id.to_s })
    result = graph

    assert_link result, "funding_borrowing", "cash_flow_node", "100.0"
    assert_nil node(result, "funding_cash")
    assert_balanced result
  end

  test "a bank-funded wallet payment carried on the card is Cash, even when the bank pays next month" do
    transaction(@wallet, 40, @shopping)
    charge = create_transaction(account: @card, amount: 40, date: @month, kind: "funds_movement")
    charge.update!(source: "paypal_funding", external_id: "paypal_funding:charge:w1")
    payment = create_transfer(from_account: @checking, to_account: @card, amount: 40, date: @month.next_month + 2)
    payment.inflow_transaction.entry.update!(source: "paypal_funding", external_id: "paypal_funding:bank:b1")

    assert_link graph, "funding_cash", "cash_flow_node", "40.0"
    assert_nil node(graph, "funding_borrowing")
    assert_equal({ nodes: [], links: [] }, graph(@month.next_month).slice(:nodes, :links), "the settling payment is not a repayment")
  end

  test "a transfer whose other leg is off the chart is Unreconciled, never hidden" do
    closed = account("Closed pot", Depository.new(subtype: "savings"))
    transaction(@checking, 100, @shopping)
    create_transfer(from_account: closed, to_account: @checking, amount: 100, date: @month + 1)
    closed.update!(status: "disabled")
    result = graph

    assert_equal "100.0", result[:unreconciled]
    assert_link result, "funding_unreconciled", "cash_flow_node", "100.0"
    assert_balanced result
  end

  test "an empty period is empty" do
    assert_equal({ nodes: [], links: [] }, graph.slice(:nodes, :links))
  end

  private
    def account(name, accountable)
      @family.accounts.create!(name: name, currency: "USD", balance: 0, accountable: accountable)
    end

    def category(name, parent: nil)
      @family.categories.create!(name: name, color: "#123456", parent: parent)
    end

    def transaction(account, amount, category, kind: "standard")
      create_transaction(account: account, amount: amount, category: category, date: @month, kind: kind)
    end

    def graph(month = @month)
      period = Period.custom(start_date: month, end_date: month.end_of_month)
      IncomeStatement::FundingSankey.new(IncomeStatement.new(@family), period: period, env: @env).as_json
    end

    def node(graph, id)
      graph[:nodes].find { |node| node[:id] == id }
    end

    def assert_link(graph, source_id, target_id, value)
      ids = graph[:nodes].map { |node| node[:id] }
      link = graph[:links].find { |l| l[:source] == ids.index(source_id) && l[:target] == ids.index(target_id) }
      assert link, "expected a link #{source_id} -> #{target_id}, got #{graph[:links].map { |l| "#{ids[l[:source]]}->#{ids[l[:target]]} #{l[:value]}" }}"
      assert_equal value, link[:value]
    end

    # Cash Flow takes in what it pays out, and every node matches its links.
    def assert_balanced(graph)
      center = graph[:nodes].index { |node| node[:id] == "cash_flow_node" }
      incoming = graph[:links].select { |l| l[:target] == center }.sum { |l| l[:value].to_d }
      outgoing = graph[:links].select { |l| l[:source] == center }.sum { |l| l[:value].to_d }
      assert_equal incoming, outgoing, "Cash Flow must balance"
      graph[:nodes].each_with_index do |node, index|
        sides = %i[target source].map { |end_point| graph[:links].select { |l| l[end_point] == index }.sum { |l| l[:value].to_d } }
        assert_equal node[:value].to_d, sides.max, "#{node[:id]} must match its links"
      end
    end
end
