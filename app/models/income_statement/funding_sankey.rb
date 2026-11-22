# Cash-flow Sankey that shows how the period was financed instead of a
# Surplus/Deficit balancing node.
#
# Left (sources): income categories grouped into families (Income, Investment
# Returns, Monies Received, Asset Sales), plus the net moves of three balance
# groups: Cash (current accounts fell), Withdrawals from Savings (savings fell)
# and Borrowing (card or loan debt rose, broken down by kind).
# Right (uses): expense categories as the category Sankey nets them, plus
# Increase in Cash on Hand, Savings, and Loan Repayments > Credit Card / Loan
# Principal for the opposite moves. Each balance group sits on one side per
# period; each kind of borrowing nets only against itself, so a loan that pays
# off the cards shows as Loans borrowed and Credit Card Principal repaid.
#
# Accounts outside the three groups (investments, crypto, property) are
# neutral: what happens inside them is not shown. Contributions into them show
# once, under their category, and cash arriving FROM them is an Asset Sale.
# Whatever cannot be attributed is its own Unreconciled node.
class IncomeStatement::FundingSankey
  FAMILIES = %w[income investment_returns monies_received asset_sales].freeze
  # Category ids (comma lists in ENV) that pick an income category's family.
  # Unlisted income categories count as Income.
  FAMILY_SETTINGS = {
    "investment_returns" => "FUNDING_RETURNS_CATEGORIES",
    "monies_received" => "FUNDING_RECEIVED_CATEGORIES",
    "asset_sales" => "FUNDING_ASSET_SALES_CATEGORIES"
  }.freeze
  # Categories that mark a move into or out of a savings place that is not an
  # account of its own (a space or pot inside a current account): the row counts
  # as a savings balance move, never as income or spending.
  SAVINGS_SETTING = "FUNDING_SAVINGS_CATEGORIES".freeze
  # The expense category that Credit Card Principal sits under.
  LOAN_REPAYMENTS_SETTING = "FUNDING_LOAN_REPAYMENTS_CATEGORY".freeze
  # Without that category: the interest category nested beside the principal.
  INTEREST_SETTING = "FUNDING_INTEREST_CATEGORY".freeze

  LABELS = {
    "income" => "Income", "investment_returns" => "Investment Returns", "monies_received" => "Monies Received",
    "asset_sales" => "Asset Sales", "cash" => "Cash", "withdrawals_from_savings" => "Withdrawals from Savings",
    "borrowing" => "Borrowing", "savings" => "Savings", "cash_on_hand" => "Increase in Cash on Hand",
    "loan_repayments" => "Loan Repayments", "credit_card_principal" => "Credit Card Principal",
    "loan_principal" => "Loan Principal", "credit_cards" => "Credit Cards", "loans" => "Loans",
    "unreconciled" => "Unreconciled"
  }.freeze

  # Each kind of borrowing: its account type and its repayment line.
  BORROWING = {
    credit_cards: { accountable_type: "CreditCard", principal: "credit_card_principal" },
    loans: { accountable_type: "Loan", principal: "loan_principal" }
  }.freeze

  COLORS = {
    "income" => "#16a34a", "investment_returns" => "#0d9488", "monies_received" => "#65a30d",
    "asset_sales" => "#2563eb", "cash" => "#8b5cf6", "savings" => "#a855f7", "borrowing" => "#dc2626",
    "loan_repayments" => "#ea580c", "unreconciled" => "#737373"
  }.freeze

  def initialize(statement, period:, env: ENV)
    @statement, @period, @env = statement, period, env
    @family = statement.family
  end

  def as_json(*)
    collect
    @nodes, @links = [], []
    left_total = @sources.values.sum + @income.values.sum
    right_total = @uses.values.sum + @expense.values.sum
    gap = (left_total - right_total).round(2)
    @sources["unreconciled"] += -gap if gap.negative?
    @uses["unreconciled"] += gap if gap.positive?
    capacity = [ left_total, right_total ].max
    unless capacity.zero?
      center = add_node("cash_flow_node", "Cash Flow", :cash_flow, capacity, 100)
      add_income(center, capacity)
      add_sources(center, capacity)
      add_expense(center, capacity)
      add_uses(center, capacity)
    end
    income = @income.values.sum
    spending = @expense.values.sum
    { basis: "net_by_funding", income: decimal(income), spending: decimal(spending),
      net_savings: decimal(income - spending), unreconciled: decimal(gap.abs), nodes: @nodes, links: @links }
  end

  private
    attr_reader :family

    # One pass over the period's transactions on the chart's accounts.
    def collect
      net = Hash.new(0.to_d)       # category => net amount out (refunds net, as the category Sankey does)
      @group_net = Hash.new(0.to_d) # + = money drawn from the group
      @asset_sales = 0.to_d
      skip = carry_entry_ids
      entries.each do |entry|
        next if skip.include?(entry.id)
        transaction = entry.entryable
        next if transaction.pending?
        amount = converted(entry)
        next if amount.nil?
        group = group_of(entry.account)
        next unless group # inside an investment, crypto or property account: neutral

        @group_net[group] += amount
        if transfer_kind?(transaction) || repays_charted_debt?(transaction)
          follow_transfer(entry, transaction, group, amount)
          next
        end

        category = transaction.category
        if category && savings_marker_ids.include?(category.id)
          @group_net[:savings] -= amount
        else
          net[category || uncategorized] += cash_outflow(transaction, amount)
        end
      end
      @expense = net.select { |_, v| v.positive? }
      @income = net.select { |_, v| v.negative? }.transform_values(&:-@)
      @sources = Hash.new(0.to_d)
      @uses = Hash.new(0.to_d)
      @sources["asset_sales"] += @asset_sales if @asset_sales.positive?
      place(:cash, "cash", "cash_on_hand")
      place(:savings, "withdrawals_from_savings", "savings")
      @borrowed = Hash.new(0.to_d)  # kind => debt taken on (left)
      @principal = Hash.new(0.to_d) # kind => debt paid down (right)
      BORROWING.each_key do |kind|
        net = @group_net[kind].round(2)
        @borrowed[kind] += net if net.positive?
        @principal[kind] += -net if net.negative?
      end
      @sources["borrowing"] = @borrowed.values.sum
      @uses["principal"] = @principal.values.sum
    end

    def place(group, source, use)
      net = @group_net[group].round(2)
      @sources[source] += net if net.positive?
      @uses[use] += -net if net.negative?
    end

    # Cash arriving from an investment, crypto or property account is a sale.
    # A transfer whose other leg is off the chart (a disabled account) stays in
    # its group's move; if the leg is missing it is Unreconciled at worst.
    # A card row the PayPal matcher linked to a wallet payment: the card paid,
    # not the wallet (who paid is the last hop).
    def follow_transfer(entry, transaction, group, amount)
      partner = transaction.transfer_as_inflow&.outflow_transaction&.entry
      if partner && amount.negative? && group_of(partner.account).nil? && eligible_ids.include?(partner.account_id)
        @asset_sales += -amount
        return
      end
      return if transaction.transfer_as_inflow || transaction.transfer_as_outflow
      return neutral(group, amount) unless BORROWING.key?(group)

      wallet_group = if (plan = transaction.extra&.dig("pay_in_3_plan")) && entry.source == "pay_in_3"
        pay_in_3_wallet_groups[plan] # a Pay in 3 plan's charge or seller refund
      elsif (wallet = wallet_entries[transaction.extra&.dig("wallet_funding_entry_id").to_s])
        group_of(wallet.account)
      end
      wallet_group ? @group_net[wallet_group] -= amount : neutral(group, amount)
    end

    # A one-sided row someone marked as a transfer (a hop through a holding
    # pot that is not an account of its own): neither a source nor a use.
    def neutral(group, amount)
      @group_net[group] -= amount
    end

    # Pay in 3 plan => the group of the wallet its purchases were paid from.
    def pay_in_3_wallet_groups
      @pay_in_3_wallet_groups ||= Entry.joins("JOIN transactions pt ON pt.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
        .where("pt.extra ? 'pay_in_3_plan'").where.not(account_id: borrowing_account_ids)
        .where.not(source: "pay_in_3").includes(:account)
        .each_with_object({}) { |e, map| map[e.entryable.extra["pay_in_3_plan"]] ||= group_of(e.account) }
    end

    # The PayPal matcher carries a bank-funded PayPal payment on the PayPal
    # Credit card until the bank debit arrives ("PayPal, paid by bank: ..."
    # and "Bank payment to PayPal"). No credit is used: the bank paid. Skip
    # the carry rows and the bank leg that settles them, so the wallet
    # payment counts as Cash even when the bank debit lands in a later period.
    def carry_entry_ids
      carries = Entry.where(account_id: borrowing_account_ids, source: "paypal_funding", date: date_range)
                     .where("external_id LIKE 'paypal_funding:charge:%' OR external_id LIKE 'paypal_funding:bank:%'")
                     .includes(:entryable).to_a
      bank_legs = carries.filter_map { |e| e.entryable.transfer_as_inflow&.outflow_transaction&.entry&.id }
      (carries.map(&:id) + bank_legs).to_set
    end

    def entries
      Entry.where(account_id: eligible_ids, excluded: false, entryable_type: "Transaction", date: date_range)
           .includes(:account, entryable: [ { category: :parent }, :transfer_as_inflow, :transfer_as_outflow ])
           .order(:date)
    end

    def wallet_entries
      @wallet_entries ||= begin
        ids = Transaction.joins(:entry).where(entries: { account_id: borrowing_account_ids, date: date_range })
                         .where("transactions.extra ? 'wallet_funding_entry_id'")
                         .pluck(Arel.sql("transactions.extra ->> 'wallet_funding_entry_id'"))
        Entry.where(id: ids).includes(:account).index_by { |e| e.id.to_s }
      end
    end

    def group_of(account)
      case account.accountable_type
      when "CreditCard" then :credit_cards
      when "Loan" then :loans
      when "Depository" then account.subtype == "savings" ? :savings : :cash
      end
    end

    def eligible_accounts = @eligible_accounts ||= @statement.eligible_accounts.to_a
    def eligible_ids = @eligible_ids ||= eligible_accounts.map(&:id).to_set
    def borrowing_account_ids = eligible_accounts.select { |a| BORROWING.key?(group_of(a)) }.map(&:id)
    def date_range = @period.start_date..@period.end_date

    def transfer_kind?(transaction) = Transaction::BUDGET_EXCLUDED_KINDS.include?(transaction.kind)

    # A loan payment whose other leg lands on a card or loan on the chart is a
    # balance move (it shows as principal), not spending. Paid to a debt that
    # is off the chart, it stays spending under its category.
    def repays_charted_debt?(transaction)
      return false unless transaction.kind == "loan_payment"
      partner = transaction.transfer_as_outflow&.inflow_transaction&.entry
      partner.present? && eligible_ids.include?(partner.account_id) && BORROWING.key?(group_of(partner.account))
    end

    def cash_outflow(transaction, amount)
      %w[investment_contribution loan_payment].include?(transaction.kind) ? amount.abs : amount
    end

    def uncategorized = @uncategorized ||= Category.uncategorized

    def family_for(category)
      return "monies_received" if category.uncategorized?
      root_id = category.parent_id || category.id
      FAMILY_SETTINGS.each { |family_key, setting| return family_key if (ids_from_env(setting) & [ category.id, root_id ]).any? }
      "income"
    end

    def savings_marker_ids = @savings_marker_ids ||= ids_from_env(SAVINGS_SETTING).to_set

    def ids_from_env(key)
      @env.fetch(key, "").split(",").map(&:strip).reject(&:blank?)
    end

    def interest_category
      id = ids_from_env(INTEREST_SETTING).first
      id && family.categories.find_by(id: id)
    end

    def loan_repayments_category
      return @loan_repayments_category if defined?(@loan_repayments_category)
      id = ids_from_env(LOAN_REPAYMENTS_SETTING).first
      @loan_repayments_category = id && family.categories.find_by(id: id)
    end

    def converted(entry)
      return entry.amount.to_d if entry.currency == family.currency
      entry.amount_money.exchange_to(family.currency, date: entry.date).amount.to_d
    rescue Money::ConversionError
      nil
    end

    # --- nodes -------------------------------------------------------------

    def add_income(center, capacity)
      @income.group_by { |category, _| family_for(category) }.sort_by { |key, _| FAMILIES.index(key) }.each do |key, rows|
        total = rows.sum { |_, v| v }
        node = add_node("funding_#{key}", label(key), :income, total, percentage(total, capacity), color: COLORS[key])
        add_link(node, center, total, percentage(total, capacity))
        rows.sort_by { |_, v| -v }.each do |category, value|
          next if category.name == label(key) && rows.size == 1
          child = add_node("income_sub_#{category_key(category)}", category.name, :income, value, percentage(value, total), category)
          add_link(child, node, value, percentage(value, total))
        end
      end
    end

    def add_sources(center, capacity)
      %w[cash withdrawals_from_savings borrowing unreconciled].each do |key|
        value = @sources[key]
        next unless value.positive?
        color = COLORS[key == "withdrawals_from_savings" ? "savings" : key]
        node = add_node("funding_#{key}", label(key), :funding, value, percentage(value, capacity), color: color)
        add_link(node, center, value, percentage(value, capacity))
        add_borrowing_kinds(node, value) if key == "borrowing"
      end
      if (asset = @sources["asset_sales"]).positive?
        node = @nodes.index { |n| n[:id] == "funding_asset_sales" }
        if node
          bump(node, asset, capacity)
        else
          node = add_node("funding_asset_sales", label("asset_sales"), :income, asset, percentage(asset, capacity), color: COLORS["asset_sales"])
          add_link(node, center, asset, percentage(asset, capacity))
        end
      end
    end

    # Borrowing always shows what it was, even when there is one kind.
    def add_borrowing_kinds(parent, total)
      @borrowed.select { |_, v| v.positive? }.each do |kind, value|
        child = add_node("funding_sub_borrowing_#{kind}", label(kind.to_s), :funding, value, percentage(value, total), color: COLORS["borrowing"])
        add_link(child, parent, value, percentage(value, total))
      end
    end

    def add_expense(center, capacity)
      tree = Hash.new { |h, k| h[k] = [] }
      @expense.each { |category, value| tree[category.parent || category] << [ category, value ] }
      principal = @uses["principal"]
      loan_root = loan_repayments_category
      tree[loan_root] if loan_root && principal.positive?
      # With no Loan Repayments category, interest sits beside the principal
      # under a Loan Repayments node of its own.
      interest_root = !loan_root && interest_category
      interest = interest_root ? tree.delete(interest_root).to_a.sum { |_, v| v } : 0
      tree.sort_by { |root, rows| -(rows.sum { |_, v| v } + (root == loan_root ? principal : 0)) }.each do |root, rows|
        extra = root == loan_root ? principal : 0
        total = rows.sum { |_, v| v } + extra
        node = add_node("expense_#{category_key(root)}", root.name, :expense, total, percentage(total, capacity), root)
        add_link(center, node, total, percentage(total, capacity))
        rows.reject { |category, _| category == root }.sort_by { |_, v| -v }.each do |category, value|
          child = add_node("expense_sub_#{category_key(category)}", category.name, :expense, value, percentage(value, total), category)
          add_link(node, child, value, percentage(value, total))
        end
        add_principal(node, extra, total) if extra.positive?
      end
      return if loan_root
      total = principal + interest
      return unless total.positive?
      node = add_node("funding_loan_repayments", label("loan_repayments"), :funding, total, percentage(total, capacity), color: COLORS["loan_repayments"])
      add_link(center, node, total, percentage(total, capacity))
      add_principal(node, principal, total) if principal.positive?
      if interest.positive?
        child = add_node("expense_#{category_key(interest_root)}", interest_root.name, :expense, interest, percentage(interest, total), interest_root)
        add_link(node, child, interest, percentage(interest, total))
      end
    end

    def add_principal(parent, _value, total)
      @principal.select { |_, v| v.positive? }.each do |kind, value|
        key = BORROWING.dig(kind, :principal)
        child = add_node("funding_sub_#{key}", label(key), :funding, value, percentage(value, total), color: COLORS["loan_repayments"])
        add_link(parent, child, value, percentage(value, total))
      end
    end

    def add_uses(center, capacity)
      %w[savings cash_on_hand unreconciled].each do |key|
        value = @uses[key]
        next unless value.positive?
        node = add_node("funding_use_#{key}", label(key), :funding, value, percentage(value, capacity), color: COLORS[key == "cash_on_hand" ? "cash" : key])
        add_link(center, node, value, percentage(value, capacity))
      end
    end

    def bump(index, value, capacity)
      node = @nodes[index]
      node[:value] = decimal(node[:value].to_d + value)
      node[:percentage] = decimal(percentage(node[:value].to_d, capacity))
      link = @links.find { |l| l[:source] == index && l[:target] == 0 }
      link[:value] = node[:value]
      link[:percentage] = node[:percentage]
    end

    def label(key)
      I18n.t("income_statement.funding_sankey.#{key}", default: LABELS.fetch(key))
    end

    def category_key(category) = IncomeStatement::CategoryNetting.key(category)

    def add_node(id, name, kind, value, percentage, category = nil, color: category&.color)
      @nodes << { id: id, name: name, kind: kind.to_s, value: decimal(value), percentage: decimal(percentage),
        category_id: category&.id, filter_value: category && !category.other_investments? ? category.filter_value : nil,
        color: category ? color.presence || Category::UNCATEGORIZED_COLOR : color } # Cash Flow: nil, the chart's own green
      @nodes.size - 1
    end

    def add_link(source, target, value, percentage)
      @links << { source: source, target: target, value: decimal(value), percentage: decimal(percentage) }
    end

    def percentage(value, total) = total.zero? ? 0 : (value.to_d / total * 100).round(1)
    def decimal(value) = value.to_d.round(2).to_s("F")
end
