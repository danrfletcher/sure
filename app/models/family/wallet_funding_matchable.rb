module Family::WalletFundingMatchable
  DEFAULT_WALLET_FUNDING_DAYS = 30

  # Opt-in (WALLET_FUNDING_ACCOUNTS=PayPal). A payment wallet such as PayPal pays the
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
  def auto_match_wallet_funding!
    wallet_names = ENV.fetch("WALLET_FUNDING_ACCOUNTS", "").split(",").map { |n| n.strip.downcase }.reject(&:blank?)
    return 0 if wallet_names.empty?

    patterns = ENV.fetch("WALLET_FUNDING_BANK_NAMES", "").split(",").map { |n| n.strip.downcase }.reject(&:blank?)
    patterns = wallet_names if patterns.empty?
    window = Integer(ENV.fetch("WALLET_FUNDING_DAYS", DEFAULT_WALLET_FUNDING_DAYS), exception: false)
    window = DEFAULT_WALLET_FUNDING_DAYS if window.nil? || window.negative?

    wallets = accounts.where("LOWER(accounts.name) IN (?)", wallet_names).to_a
    return 0 if wallets.empty?

    wallet_ids = wallets.map(&:id)
    own = Entry.where(entryable_type: "Transaction", account_id: accounts.select(:id)).joins("INNER JOIN transactions ON transactions.id = entries.entryable_id")

    already_used = own.where.not(account_id: wallet_ids)
      .where("transactions.extra ? 'wallet_funding_entry_id'")
      .pluck(Arel.sql("transactions.extra ->> 'wallet_funding_entry_id'"))
    used = already_used.to_set

    wallet_rows = own.where(account_id: wallet_ids).where("entries.amount > 0")
      .where("transactions.kind = 'standard'").order(:date, :created_at).to_a

    bank_scope = own.where.not(account_id: wallet_ids).where("entries.amount > 0")
      .where("transactions.kind = 'standard'")
      .where(patterns.map { "LOWER(entries.name) LIKE ?" }.join(" OR "), *patterns.map { |p| "%#{p}%" })
      .order(:date, :created_at)

    matched = 0
    bank_scope.each do |bank|
      wallet = wallet_rows.find do |w|
        !used.include?(w.id.to_s) &&
          w.currency == bank.currency &&
          (w.amount - bank.amount).abs < 0.005 &&
          (0..window).cover?((bank.date - w.date).to_i)
      end
      next unless wallet

      used << wallet.id.to_s
      transaction = bank.entryable
      transaction.update!(kind: "funds_movement", extra: transaction.extra.merge("wallet_funding_entry_id" => wallet.id.to_s))
      matched += 1
    end

    matched
  end
end
