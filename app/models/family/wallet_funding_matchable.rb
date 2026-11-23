module Family::WalletFundingMatchable
  DEFAULT_WALLET_FUNDING_DAYS = 30
  DEFAULT_WALLET_FUNDING_FX_TOLERANCE = 0.05

  # Opt-in (WALLET_FUNDING_ACCOUNTS=<the wallet account's id>, comma-separated for several;
  # ids, not names, so renaming an account never switches this off). A payment wallet such as PayPal pays the
  # merchant first, and the bank is charged for it afterwards. Sure then holds the same
  # spending twice: a merchant row in the wallet account and a payment to the wallet's
  # name in the bank account.
  #
  # For every bank payment whose name matches WALLET_FUNDING_BANK_NAMES (comma-separated,
  # case-insensitive substrings; defaults to the wallet account names), this finds the
  # earliest unmatched wallet row with the same amount and currency, dated on or up to
  # WALLET_FUNDING_DAYS (default 30) before the bank payment, and marks the bank row a
  # funds movement so it drops out of reports. The wallet row is the spending and keeps
  # its own category. Bank payments with no wallet row, and wallet rows with no bank
  # payment, are left exactly as they are. The bank row records which wallet row it
  # matched, so a wallet row is never used twice.
  #
  # Second pass, for wallet rows in another currency (the bank charges its own conversion):
  # a bank payment still unmatched is paired with a wallet row when the row's amount,
  # converted at Sure's rate for the row's date, is within WALLET_FUNDING_FX_TOLERANCE
  # (default 0.05) of the bank amount, inside the same window, and ONLY when that is the
  # single wallet row that fits and no other unmatched bank payment fits it either.
  #
  # With dry_run: true nothing is written; returns the pairs as [bank_entry, wallet_entry, pass].
  # exclude_wallet_ids are wallet rows another rule has already claimed (for dry runs).
  def auto_match_wallet_funding!(dry_run: false, exclude_wallet_ids: [])
    wallets = accounts_from_env("WALLET_FUNDING_ACCOUNTS")
    return(dry_run ? [] : 0) if wallets.empty?

    patterns = ENV.fetch("WALLET_FUNDING_BANK_NAMES", "").split(",").map { |n| n.strip.downcase }.reject(&:blank?)
    patterns = wallets.map { |w| w.name.downcase } if patterns.empty?
    window = Integer(ENV.fetch("WALLET_FUNDING_DAYS", DEFAULT_WALLET_FUNDING_DAYS), exception: false)
    window = DEFAULT_WALLET_FUNDING_DAYS if window.nil? || window.negative?

    wallet_ids = wallets.map(&:id)
    own = Entry.where(entryable_type: "Transaction", account_id: accounts.select(:id)).joins("INNER JOIN transactions ON transactions.id = entries.entryable_id")

    already_used = own.where.not(account_id: wallet_ids)
      .where("transactions.extra ? 'wallet_funding_entry_id'")
      .pluck(Arel.sql("transactions.extra ->> 'wallet_funding_entry_id'"))
    used = already_used.to_set + exclude_wallet_ids.map(&:to_s)

    wallet_rows = own.where(account_id: wallet_ids).where("entries.amount > 0")
      .where("transactions.kind = 'standard' OR (transactions.kind = 'cc_payment' AND transactions.extra ? 'pay_in_3_plan')")
      .order(:date, :created_at).to_a

    bank_scope = own.where.not(account_id: wallet_ids).where("entries.amount > 0")
      .where("transactions.kind = 'standard'")
      .where(patterns.map { "LOWER(entries.name) LIKE ?" }.join(" OR "), *patterns.map { |p| "%#{p}%" })
      .order(:date, :created_at)

    tolerance = Float(ENV.fetch("WALLET_FUNDING_FX_TOLERANCE", DEFAULT_WALLET_FUNDING_FX_TOLERANCE), exception: false)
    tolerance = DEFAULT_WALLET_FUNDING_FX_TOLERANCE if tolerance.nil? || !tolerance.finite? || tolerance.negative?

    pairs = []
    unmatched = []
    bank_scope.each do |bank|
      wallet = wallet_rows.find do |w|
        !used.include?(w.id.to_s) &&
          w.currency == bank.currency &&
          (w.amount - bank.amount).abs < 0.005 &&
          (0..window).cover?((bank.date - w.date).to_i)
      end
      if wallet
        used << wallet.id.to_s
        pairs << [ bank, wallet, :same_amount ]
      else
        unmatched << bank
      end
    end

    foreign = wallet_rows.reject { |w| used.include?(w.id.to_s) }
    fits = lambda do |bank, w|
      next false if w.currency == bank.currency || !(0..window).cover?((bank.date - w.date).to_i)

      rate = ExchangeRate.find_or_fetch_rate(from: w.currency, to: bank.currency, date: w.date)&.rate
      rate.present? && ((w.amount * rate) - bank.amount).abs <= bank.amount * tolerance
    end

    unmatched.each do |bank|
      candidates = foreign.select { |w| fits.call(bank, w) }
      next unless candidates.one?

      wallet = candidates.first
      next if unmatched.count { |other| other != bank && fits.call(other, wallet) } > 0

      pairs << [ bank, wallet, :converted ]
      foreign = foreign - [ wallet ]
    end

    return pairs if dry_run

    pairs.each do |bank, wallet, _pass|
      transaction = bank.entryable
      transaction.update!(kind: "funds_movement", extra: transaction.extra.merge("wallet_funding_entry_id" => wallet.id.to_s))
    end

    pairs.size
  end
end
