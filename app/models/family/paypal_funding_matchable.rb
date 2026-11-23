module Family::PaypalFundingMatchable
  CARD_FUNDING_DAYS = 3
  PENDING_DAYS = 14
  WITHDRAWAL_DAYS = 5
  SPLIT_CREDIT_DAYS = 90
  SPLIT_DUST = 0.02
  # PayPal converts a foreign-currency payment at its own rate, about 4-5% above market, so
  # the card's charge sits further from Sure's rate than a bank's own conversion does.
  CARD_FX_TOLERANCE = 0.07

  # Opt-in (PAY_IN_3_ACCOUNT is the PayPal wallet's account id, PAYPAL_CREDIT_CARD the id of
  # the credit-card account that carries what PayPal is owed). Runs in place of
  # auto_match_wallet_funding! and works out how each wallet payment was paid for:
  #
  #   1. Card-funded: a charge on a linked card or current account within CARD_FUNDING_DAYS
  #      either side of the payment (a card can book before PayPal does), for the same amount,
  #      or for a foreign-currency payment its value at Sure's rate within CARD_FX_TOLERANCE,
  #      and the only such pair either way. Cards that mark it
  #      ("PAYPAL *EBAY") may be any amount; a charge that names only the merchant (Monzo)
  #      must not be a whole-pound amount, so a coincidence is unlikely.
  #      The card row turns neutral and the wallet row stays the spending, taking the card
  #      row's category if it has none.
  #   2. Bank-funded: auto_match_wallet_funding! pairs the bank's PayPal payment with it.
  #   3. Split with returned money: a bank payment smaller than the wallet payment, where the
  #      gap is a credit PayPal put in the wallet beforehand (a refund), and only one such fit.
  #   4. Withdrawals: a wallet MONEY_TRANSFER and the bank's same-amount PayPal credit a few
  #      days later become a transfer between them.
  #   5. What PayPal is owed: every bank-funded wallet payment charges the card on the day of
  #      the wallet payment and the bank payment pays it off. A wallet payment with no match
  #      yet is charged provisionally for PENDING_DAYS; after that (or once a card matches)
  #      the provisional charge is removed and the payment is left as ordinary spending.
  #
  # Rows a user excluded are never touched. With dry_run: true nothing is written and the
  # planned pairs are returned.
  def auto_match_paypal_funding!(dry_run: false)
    wallet = account_from_env("PAY_IN_3_ACCOUNT")
    card = account_from_env("PAYPAL_CREDIT_CARD", type: "CreditCard")
    unless wallet && card
      return dry_run ? { wallet_funding: auto_match_wallet_funding!(dry_run: true) } : auto_match_wallet_funding!
    end

    plan = { card_funded: paypal_card_funding_pairs(wallet, card) }
    exclude = plan[:card_funded].map { |_, w| w.id.to_s }
    if dry_run
      plan[:wallet_funding] = auto_match_wallet_funding!(dry_run: true, exclude_wallet_ids: exclude)
      exclude += plan[:wallet_funding].map { |_, w, _| w.id.to_s }
      plan[:split] = paypal_split_pairs(wallet, exclude)
      plan[:withdrawals] = paypal_withdrawal_pairs(wallet)
      plan[:liability] = paypal_liability_todo(card, extra_pairs: plan[:wallet_funding].map { |b, w, _| [ b, w ] } + plan[:split].map { |b, w, _| [ b, w ] })
      plan[:pending], plan[:parked] = paypal_pending(wallet, exclude + plan[:split].map { |_, w, _| w.id.to_s })
      return plan
    end

    plan[:card_funded].each do |row, w|
      t = row.entryable
      t.update!(kind: "funds_movement", extra: t.extra.merge("wallet_funding_entry_id" => w.id.to_s, "paypal_funding" => "card"))
      w.entryable.update!(category: t.category) if w.entryable.category.nil? && t.category.present?
    end
    auto_match_wallet_funding!
    paypal_split_pairs(wallet, []).each do |bank, w, credit|
      t = bank.entryable
      t.update!(kind: "funds_movement", extra: t.extra.merge("wallet_funding_entry_id" => w.id.to_s, "paypal_funding" => "split", "paypal_split_credit_id" => credit.id.to_s))
    end
    paypal_withdrawal_pairs(wallet).each do |wallet_row, bank|
      Account.transaction do
        existing = bank.entryable.transfer
        if existing
          existing.confirm!
        else
          Transfer.new(inflow_transaction: bank.entryable, outflow_transaction: wallet_row.entryable, status: "confirmed").save!
        end
        wallet_row.entryable.update!(kind: "funds_movement")
        bank.entryable.update!(kind: "funds_movement")
      end
    end
    changed = paypal_apply_liability(card)
    pending, = paypal_pending(wallet, [])
    changed += paypal_sync_provisional(card, pending)
    card.sync_later if changed > 0
    plan[:card_funded].size + changed
  end

  private
    UUID_FORMAT = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    # An account named in an env var by its id. Ids never change, so renaming an account in
    # Sure cannot silently switch a rule off; anything that is not an id is ignored.
    def account_from_env(key, type: nil)
      accounts_from_env(key, type: type).first
    end

    def accounts_from_env(key, type: nil)
      ids = ENV.fetch(key, "").split(",").map(&:strip).select { |ref| ref.match?(UUID_FORMAT) }
      return [] if ids.empty?

      scope = accounts.where(id: ids)
      scope = scope.where(accountable_type: type) if type
      scope.to_a
    end

    def paypal_wallet_patterns
      patterns = ENV.fetch("WALLET_FUNDING_BANK_NAMES", "").split(",").map { |n| n.strip.downcase }.reject(&:blank?)
      patterns.presence || [ "paypal" ]
    end

    def paypal_own_entries
      Entry.where(entryable_type: "Transaction", account_id: accounts.select(:id)).joins("INNER JOIN transactions ON transactions.id = entries.entryable_id")
    end

    def paypal_used_wallet_ids(wallet)
      paypal_own_entries.where.not(account_id: wallet.id).where("transactions.extra ? 'wallet_funding_entry_id'")
        .pluck(Arel.sql("transactions.extra ->> 'wallet_funding_entry_id'")).to_set
    end

    # Wallet payments that are ordinary spending (not Pay in 3, not excluded) and unmatched.
    def paypal_open_wallet_rows(wallet, exclude)
      used = paypal_used_wallet_ids(wallet) + exclude
      paypal_own_entries.where(account_id: wallet.id, excluded: false).where("entries.amount > 0")
        .where("transactions.kind = 'standard' AND NOT (transactions.extra ? 'pay_in_3_plan')")
        .order(:date, :created_at).to_a.reject { |w| used.include?(w.id.to_s) }
    end

    def paypal_card_funding_pairs(wallet, card)
      rows = paypal_open_wallet_rows(wallet, [])
      return [] if rows.empty?

      skip = [ wallet.id, card.id, account_from_env("PAY_IN_3_CARD")&.id ].compact
      patterns = paypal_wallet_patterns
      candidates = paypal_own_entries.where(excluded: false)
        .where(account_id: accounts.where(accountable_type: %w[Depository CreditCard]).where.not(id: skip).select(:id))
        .where("entries.amount > 0 AND transactions.kind = 'standard' AND NOT (transactions.extra ? 'wallet_funding_entry_id')")
        .where(date: (rows.first.date - CARD_FUNDING_DAYS)..(rows.last.date + CARD_FUNDING_DAYS))
        .where.not(patterns.map { "LOWER(entries.name) LIKE ?" }.join(" OR "), *patterns.map { |p| "%#{p}%" })
        .includes(:entryable).to_a

      rates = Hash.new { |h, (from, to, date)| h[[ from, to, date ]] = ExchangeRate.find_or_fetch_rate(from: from, to: to, date: date)&.rate }
      same_value = lambda do |w, c|
        next (c.amount - w.amount).abs < 0.005 if c.currency == w.currency

        rate = rates[[ w.currency, c.currency, w.date ]]
        rate.present? && ((w.amount * rate) - c.amount).abs <= c.amount * CARD_FX_TOLERANCE
      end

      fits = lambda do |w, c|
        next false unless (c.date - w.date).to_i.abs <= CARD_FUNDING_DAYS && same_value.call(w, c)

        marked = [ c.name, c.entryable.extra.to_h.dig("gocardless", "description") ].any? { |s| s.to_s.downcase.include?("paypal *") }
        marked || (c.amount % 1).nonzero?
      end

      rows.filter_map do |w|
        hits = candidates.select { |c| fits.call(w, c) }
        next unless hits.one?
        next unless rows.count { |other| fits.call(other, hits.first) } == 1

        [ hits.first, w ]
      end
    end

    def paypal_split_pairs(wallet, exclude)
      patterns = paypal_wallet_patterns
      banks = paypal_own_entries.where.not(account_id: wallet.id).where(excluded: false).where("entries.amount > 0")
        .where("transactions.kind = 'standard'")
        .where(patterns.map { "LOWER(entries.name) LIKE ?" }.join(" OR "), *patterns.map { |p| "%#{p}%" }).to_a
      open = paypal_open_wallet_rows(wallet, exclude)
      used_credits = paypal_own_entries.where("transactions.extra ? 'paypal_split_credit_id'").pluck(Arel.sql("transactions.extra ->> 'paypal_split_credit_id'")).to_set
      credits = paypal_own_entries.where(account_id: wallet.id).where("entries.amount < 0").to_a.reject { |c| used_credits.include?(c.id.to_s) }

      fits = lambda do |bank, w|
        next [] unless w.currency == bank.currency && bank.amount < w.amount && (0..30).cover?((bank.date - w.date).to_i)

        credits.select { |c| c.currency == w.currency && (0..SPLIT_CREDIT_DAYS).cover?((w.date - c.date).to_i) && (w.amount - bank.amount + c.amount).abs <= SPLIT_DUST }
      end

      banks.filter_map do |bank|
        options = open.flat_map { |w| fits.call(bank, w).map { |c| [ w, c ] } }
        next unless options.one?

        w, c = options.first
        next unless banks.count { |other| fits.call(other, w).any? } == 1

        [ bank, w, c ]
      end
    end

    def paypal_withdrawal_pairs(wallet)
      # A pending transfer Sure's own matcher made between the same two rows counts as open.
      open_leg = ->(e, other = nil) { t = e.entryable.transfer; t.nil? || (t.status == "pending" && (other.nil? || [ t.inflow_transaction_id, t.outflow_transaction_id ].include?(other.entryable.id))) }
      rows = pay_in_3_rows(wallet).select { |r| r[:code] == "MONEY_TRANSFER" && r[:dir] == "DBIT" }
        .map { |r| r[:entry] }.select { |e| e.entryable.kind == "standard" && open_leg.call(e) && !e.excluded }
      return [] if rows.empty?

      patterns = paypal_wallet_patterns
      banks = paypal_own_entries.where.not(account_id: wallet.id).where(excluded: false).where("entries.amount < 0")
        .where("transactions.kind = 'standard'")
        .where(patterns.map { "LOWER(entries.name) LIKE ?" }.join(" OR "), *patterns.map { |p| "%#{p}%" }).to_a
        .select { |b| open_leg.call(b) }
      fits = ->(w, b) { b.currency == w.currency && (b.amount + w.amount).abs < 0.005 && (0..WITHDRAWAL_DAYS).cover?((b.date - w.date).to_i) && open_leg.call(w, b) && open_leg.call(b, w) }

      rows.filter_map do |w|
        hits = banks.select { |b| fits.call(w, b) }
        next unless hits.one? && rows.count { |o| fits.call(o, hits.first) } == 1

        [ w, hits.first ]
      end
    end

    # Bank payments already paired with a wallet payment that do not yet pay off the card. A
    # pending transfer on the bank row is Sure's unconfirmed guess at an own-account move; the
    # wallet pairing outranks it (it is dropped when the card is paid).
    def paypal_liability_todo(card, extra_pairs: [])
      done = card.entries.where(source: "paypal_funding").where("external_id LIKE 'paypal_funding:bank:%'").pluck(:external_id).to_set
      linked = paypal_own_entries.where.not(account_id: card.id).where("transactions.extra ? 'wallet_funding_entry_id'")
        .where("COALESCE(transactions.extra ->> 'paypal_funding', '') <> 'card'").includes(:entryable).to_a
      wallet_entries = Entry.where(id: linked.map { |b| b.entryable.extra["wallet_funding_entry_id"] }).index_by { |e| e.id.to_s }
      pairs = linked.filter_map { |b| w = wallet_entries[b.entryable.extra["wallet_funding_entry_id"]]; [ b, w ] if w } + extra_pairs
      pairs.reject { |b, _| done.include?("paypal_funding:bank:#{b.id}") || b.currency != card.currency || b.entryable.transfer&.status == "confirmed" }
    end

    def paypal_apply_liability(card)
      todo = paypal_liability_todo(card)
      todo.each do |bank, w|
        Account.transaction do
          charge = card.entries.find_by(source: "paypal_funding", external_id: "paypal_funding:charge:#{w.id}")
          if charge
            charge.update!(amount: bank.amount, date: w.date)
            charge.entryable.update!(extra: charge.entryable.extra.except("provisional"))
          else
            card.entries.create!(source: "paypal_funding", external_id: "paypal_funding:charge:#{w.id}", date: w.date, amount: bank.amount,
                                 currency: card.currency, name: "PayPal, paid by bank: #{w.name}",
                                 entryable: Transaction.new(kind: "funds_movement", extra: { "wallet_entry_id" => w.id.to_s }))
          end
          inflow = card.entries.create!(source: "paypal_funding", external_id: "paypal_funding:bank:#{bank.id}", date: bank.date, amount: -bank.amount,
                                        currency: card.currency, name: "Bank payment to PayPal",
                                        entryable: Transaction.new(kind: "funds_movement"))
          outflow = bank.entryable
          outflow.transfer&.destroy! if outflow.transfer&.status == "pending"
          outflow.reload
          Transfer.new(inflow_transaction: inflow.entryable, outflow_transaction: outflow, status: "confirmed").save!
          outflow.update!(kind: Transfer.kind_for_account(card, from_account: bank.account))
        end
      end
      todo.size
    end

    # [pending, parked]: open wallet payments within PENDING_DAYS, and older ones left as spending.
    def paypal_pending(wallet, exclude)
      open = paypal_open_wallet_rows(wallet, exclude)
      cutoff = Date.current - PENDING_DAYS
      open.partition { |w| w.date > cutoff }
    end

    def paypal_sync_provisional(card, pending)
      changed = 0
      keep = pending.select { |w| w.currency == card.currency }.index_by { |w| w.id.to_s }
      card.entries.where(source: "paypal_funding").where("external_id LIKE 'paypal_funding:charge:%'").includes(:entryable).each do |e|
        next unless e.entryable.extra.to_h["provisional"]
        next if keep.delete(e.entryable.extra["wallet_entry_id"])

        e.destroy!
        changed += 1
      end
      keep.each_value do |w|
        card.entries.create!(source: "paypal_funding", external_id: "paypal_funding:charge:#{w.id}", date: w.date, amount: w.amount,
                             currency: card.currency, name: "PayPal, awaiting payment: #{w.name}",
                             entryable: Transaction.new(kind: "funds_movement", extra: { "wallet_entry_id" => w.id.to_s, "provisional" => true }))
        changed += 1
      end
      changed
    end
end
