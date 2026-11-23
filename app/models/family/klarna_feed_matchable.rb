module Family::KlarnaFeedMatchable
  SOURCE = "klarna".freeze
  PAYMENT_DAYS = (-1..5)        # bank debit lands this many days after Klarna's payment email
  REFUND_DAYS = (-2..14)        # refunded money reaches the bank within this window
  STATEMENT_DAYS = (-3..3)      # statement payment vs its "payment received" email
  LATE_PAYMENT_DAYS = 5
  LATE_REFUND_DAYS = 14

  # Opt-in: KLARNA_PAY_IN_3_CARD and KLARNA_CREDIT_CARD (credit-card account ids) and
  # KLARNA_BANK_ACCOUNTS (comma-separated ids of the accounts Klarna takes payments from).
  # Ids, not names, so renaming an account never switches this off.
  #
  # Klarna has no feed. Its emails are parsed outside Sure into a feed hash:
  #   pay_in_3: [{ key, merchant, order_date, total, status, payments: [{ id, date, amount }],
  #                adjustments: [{ id, date, amount }], refunds: [{ id, date, amount, cancels_order }] }]
  #   credit_card: [{ key, start, end, balance, charges, payments: [{ id, date, amount }] }]
  #
  # Pay in 3: the purchase is charged to the Pay in 3 card at its full amount (spending,
  # in the category the bank rows for that plan already had), a return or refund is a
  # credit in the same category, and each instalment the bank paid becomes a transfer from
  # the bank to the card. An order Klarna cancels is refunded in full on the card; the money
  # it sends back to the bank is a transfer from the card.
  #
  # Credit Card: one charge per statement (left uncategorised), dated the statement's last
  # day, and the bank payment of that statement becomes a transfer to the card.
  #
  # Every write is keyed by an external id, so a nightly run only adds what is new. A bank
  # row is only ever linked to one Klarna payment; anything not found is reported, not guessed.
  # With dry_run: true nothing is written and the report says what would be.
  def import_klarna_feed!(feed, dry_run: false, today: Date.current)
    feed = feed.deep_stringify_keys
    report = { booked: [], linked: [], waiting: [], warnings: [] }
    pay_in_3 = account_from_env("KLARNA_PAY_IN_3_CARD", type: "CreditCard")
    credit = account_from_env("KLARNA_CREDIT_CARD", type: "CreditCard")
    banks = accounts_from_env("KLARNA_BANK_ACCOUNTS")
    unless (pay_in_3 || credit) && banks.any?
      report[:warnings] << "Klarna is not configured"
      return report
    end

    run = KlarnaRun.new(banks, report, dry_run, today)
    Account.transaction do
      feed.fetch("pay_in_3", []).each { |plan| run.pay_in_3_plan(pay_in_3, plan) } if pay_in_3
      feed.fetch("credit_card", []).each { |statement| run.credit_statement(credit, statement) } if credit
    end
    [ pay_in_3, credit ].compact.each(&:sync_later) if !dry_run && (report[:booked].any? || report[:linked].any?)
    report
  end

  class KlarnaRun
    def initialize(banks, report, dry_run, today)
      @report, @dry_run, @today = report, dry_run, today
      @used = Set.new
      @rows = Entry.where(account_id: banks.map(&:id), entryable_type: "Transaction", excluded: false)
                   .where("entries.name ILIKE ?", "%klarna%")
                   .joins("JOIN transactions t ON t.id = entries.entryable_id")
                   .where("t.kind = 'standard'")
                   .where("NOT EXISTS (SELECT 1 FROM transfers tr WHERE tr.inflow_transaction_id = t.id OR tr.outflow_transaction_id = t.id)")
                   .includes(:entryable).order(:date).to_a
    end

    def pay_in_3_plan(card, plan)
      key = "#{SOURCE}:#{plan["key"]}"
      merchant = plan["merchant"]
      found = plan["payments"].filter_map do |pay|
        next if card.entries.exists?(external_id: "#{key}:pay:#{pay["id"]}")

        row = take_row(pay["amount"], pay["date"], PAYMENT_DAYS)
        unless row
          late = (@today - Date.parse(pay["date"])).to_i > LATE_PAYMENT_DAYS
          (late ? @report[:warnings] : @report[:waiting]) << "Klarna Pay in 3 #{merchant}: no bank debit of £#{fmt(pay["amount"])} after #{pay["date"]}"
          next
        end
        [ pay, row ]
      end

      category = category_from(found.map(&:last), merchant)
      purchase = book(card, "#{key}:purchase", plan["order_date"], plan["total"].to_d, "#{merchant} (Klarna Pay in 3)", category)
      if purchase && !@dry_run && purchase.entryable.category_id.nil? && category
        purchase.entryable.update!(category_id: category.id)
      end
      category = purchase&.entryable&.category || category

      found.each { |pay, row| link_payment(card, "#{key}:pay:#{pay["id"]}", row, key) }
      plan["adjustments"].each do |adj|
        book(card, "#{key}:adjust:#{adj["id"]}", adj["date"], -adj["amount"].to_d, "#{merchant} return (Klarna Pay in 3)", category)
      end
      plan["refunds"].each { |refund| pay_in_3_refund(card, key, plan, refund, category) }
    end

    def credit_statement(card, statement)
      key = "#{SOURCE}_credit:#{statement["key"]}"
      charges = statement["charges"].to_d
      unless charges.zero?
        name = "Klarna Credit Card #{charges.positive? ? "purchases" : "credits"}, #{statement["start"]} to #{statement["end"]}"
        book(card, "#{key}:charges", statement["end"], charges, name, nil)
      end
      statement["payments"].each do |pay|
        ext = "#{key}:pay:#{pay["id"]}"
        next if card.entries.exists?(external_id: ext)

        row = take_row(pay["amount"], pay["date"], STATEMENT_DAYS)
        if row
          link_payment(card, ext, row, key)
        else
          late = (@today - Date.parse(pay["date"])).to_i > LATE_PAYMENT_DAYS
          (late ? @report[:warnings] : @report[:waiting]) << "Klarna Credit Card: no bank debit of £#{fmt(pay["amount"])} around #{pay["date"]}"
        end
      end
    end

    private

      def pay_in_3_refund(card, key, plan, refund, category)
        merchant = plan["merchant"]
        if refund["cancels_order"]
          net = plan["total"].to_d - plan["adjustments"].sum { |a| a["amount"].to_d }
          book(card, "#{key}:refund:#{refund["id"]}", refund["date"], -net, "#{merchant} order cancelled (Klarna Pay in 3)", category)
        else
          book(card, "#{key}:refund:#{refund["id"]}", refund["date"], -refund["amount"].to_d, "#{merchant} refund (Klarna Pay in 3)", category)
        end

        ext = "#{key}:refund_paid:#{refund["id"]}"
        return if card.entries.exists?(external_id: ext)

        row = take_row(-refund["amount"].to_d, refund["date"], REFUND_DAYS)
        if row
          link_refund(card, ext, row, key)
        elsif refund["cancels_order"]
          late = (@today - Date.parse(refund["date"])).to_i > LATE_REFUND_DAYS
          (late ? @report[:warnings] : @report[:waiting]) << "Klarna Pay in 3 #{merchant}: refund of £#{fmt(refund["amount"])} from #{refund["date"]} has not reached the bank"
        end
      end

      # The unused Klarna bank row with this amount (positive = money out) closest to the date.
      def take_row(amount, date, window)
        amount = amount.to_d
        date = Date.parse(date.to_s)
        row = @rows.reject { |r| @used.include?(r.id) }
                   .select { |r| (r.amount - amount).abs < 0.005 && window.cover?((r.date - date).to_i) }
                   .min_by { |r| [ (r.date - date).to_i.abs, r.date ] }
        @used << row.id if row
        row
      end

      # The category the user (or a rule) gave the plan's bank rows: rows naming the
      # merchant first, then the most recent one.
      def category_from(rows, merchant)
        token = merchant.to_s.downcase.gsub(/[^a-z0-9]/, "")[0, 5]
        rows = rows.select { |r| r.entryable.category_id }
        named = rows.select { |r| token.present? && r.name.downcase.gsub(/[^a-z0-9]/, "").include?(token) }
        (named.presence || rows).max_by(&:date)&.entryable&.category
      end

      def book(card, ext, date, amount, name, category, kind: "standard")
        existing = card.entries.find_by(external_id: ext)
        return existing if existing

        @report[:booked] << { account: card.name, date: date.to_s, amount: amount.to_f, name: name, category: category&.name }
        return nil if @dry_run

        card.entries.create!(source: SOURCE, external_id: ext, date: date, amount: amount, currency: card.currency, name: name,
                             entryable: Transaction.new(kind: kind, category: category, extra: { "klarna" => ext }))
      end

      # A bank debit that paid Klarna: a transfer from the bank to the card.
      def link_payment(card, ext, row, key)
        @report[:linked] << { account: card.name, date: row.date.to_s, amount: row.amount.to_f, bank_row: row.name, was: row.entryable.category&.name }
        return if @dry_run

        inflow = card.entries.create!(source: SOURCE, external_id: ext, date: row.date, amount: -row.amount, currency: card.currency,
                                      name: "Payment from #{row.account.name}", entryable: Transaction.new(kind: "funds_movement", extra: { "klarna" => ext }))
        outflow = row.entryable
        Transfer.new(inflow_transaction: inflow.entryable, outflow_transaction: outflow, status: "confirmed").save!
        outflow.update!(kind: Transfer.kind_for_account(card, from_account: row.account), category_id: nil,
                        extra: (outflow.extra || {}).merge("klarna_plan" => key, "klarna_prev_category_id" => outflow.category_id))
      end

      # Money Klarna sent back to the bank: a transfer from the card.
      def link_refund(card, ext, row, key)
        @report[:linked] << { account: card.name, date: row.date.to_s, amount: row.amount.to_f, bank_row: row.name, was: row.entryable.category&.name }
        return if @dry_run

        outflow = card.entries.create!(source: SOURCE, external_id: ext, date: row.date, amount: -row.amount, currency: card.currency,
                                       name: "Refund to #{row.account.name}", entryable: Transaction.new(kind: "funds_movement", extra: { "klarna" => ext }))
        inflow = row.entryable
        Transfer.new(inflow_transaction: inflow, outflow_transaction: outflow.entryable, status: "confirmed").save!
        inflow.update!(kind: "funds_movement", category_id: nil,
                       extra: (inflow.extra || {}).merge("klarna_plan" => key, "klarna_prev_category_id" => inflow.category_id))
      end

      def fmt(amount) = format("%.2f", amount.to_f.abs)
  end
end
