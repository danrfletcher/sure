module Family::PayIn3Matchable
  DUST = 0.03
  REFUND_WINDOW_DAYS = 90
  LATER_WINDOW = (25..75)

  # Opt-in (PAY_IN_3_ACCOUNT=<wallet account id>, PAY_IN_3_CARD=<credit-card account id>; ids,
  # not names, so renaming either account never switches this off. The card must exist).
  #
  # PayPal Pay in 3 pays the merchant in full on day one and then takes three equal
  # instalments from the wallet, a month apart. In the bank feed the purchase is an
  # ordinary payment row and each instalment is a LOAN-coded debit. Left alone, Sure
  # counts the purchase and all three instalments as spending.
  #
  # This models the debt on a credit-card account:
  #   * the purchase row stays as the spending (it keeps its category);
  #   * the card is charged the purchase amount (a neutral entry);
  #   * each instalment row becomes a transfer from the wallet to the card;
  #   * a seller refund that reduces the plan is a neutral credit on the card.
  #
  # A plan starts from a purchase that has a LOAN debit of one third of it (+-3p) on the
  # same day. A checkout of several items from one merchant (PayPal splits the first
  # instalment per item and the feed omits refunded items) is grouped by day and merchant
  # and charged at three times the day's first instalments. Whatever is left is cleared
  # only by a unique set of later LOAN debits and refund credits; otherwise the plan stays
  # open. A LOAN debit that no plan claims is never touched. It stays as spending.
  #
  # With dry_run: true nothing is written and the plans are returned.
  def auto_match_pay_in_3!(dry_run: false)
    wallet = account_from_env("PAY_IN_3_ACCOUNT")
    card = account_from_env("PAY_IN_3_CARD", type: "CreditCard")
    return(dry_run ? { plans: [], parked: [] } : 0) unless wallet && card

    rows = pay_in_3_rows(wallet)
    return(dry_run ? { plans: [], parked: [] } : 0) if rows.empty?

    result = Family::PayIn3Matchable.plan(rows)
    return result if dry_run

    Family::PayIn3Matchable.apply(self, wallet, card, result[:plans])
  end

  def self.plan(rows)
    loans = rows.select { |r| r[:code] == "LOAN" && r[:dir] == "DBIT" }.sort_by { |r| r[:date] }
    purchases = rows.select { |r| r[:code] == "PAYMENT" && r[:dir] == "DBIT" && r[:currency] == "GBP" }
    refunds = rows.select { |r| r[:code] == "REFUND" && r[:dir] == "CRDT" }
    taken = {}
    plans = []

    purchases.group_by { |p| [ p[:date], p[:merchant] ] }.sort_by { |(date, _), _| date }.each do |(date, _), group|
      firsts = []
      bought = []
      group.each do |p|
        f = loans.find { |l| !taken[l[:id]] && l[:date] == date && (3 * l[:amount] - p[:amount]).abs <= DUST }
        next unless f

        taken[f[:id]] = true
        firsts << f
        bought << p
      end
      next if firsts.empty?

      multi = bought.size > 1
      charge = multi ? nil : bought.sum { |p| p[:amount] }
      charge = charge&.round(2)
      plans << { date: date, merchant: bought.first[:merchant], purchases: bought, charge: charge, instalments: firsts, credits: [], multi: multi }
    end

    # A multi-item checkout: PayPal splits the first instalment per item, and the feed omits
    # purchase rows for items refunded later. Those instalments are the day's loan debits that
    # no single-purchase plan claimed, and only when exactly one checkout started that day.
    plans.select { |pl| pl[:multi] }.group_by { |pl| pl[:date] }.each do |date, same_day|
      next unless same_day.one?

      extra = loans.select { |l| !taken[l[:id]] && l[:date] == date }
      extra.each { |l| taken[l[:id]] = true }
      same_day.first[:instalments].concat(extra)
    end
    plans.select { |pl| pl[:multi] }.each { |pl| pl[:charge] = (pl[:instalments].sum { |f| f[:amount] } * 3).round(2) }

    # later instalments: same amount about a month apart, then single lump payoffs
    plans.each do |pl|
      pl[:instalments].dup.each do |f|
        2.times do
          last = pl[:instalments].select { |i| (i[:amount] - f[:amount]).abs <= DUST }.max_by { |i| i[:date] }
          nxt = loans.find { |x| !taken[x[:id]] && (x[:amount] - f[:amount]).abs <= DUST && LATER_WINDOW.cover?((x[:date] - last[:date]).to_i) && pl[:instalments].count { |i| (i[:amount] - f[:amount]).abs <= DUST } < 3 * pl[:purchases].size }
          break unless nxt

          taken[nxt[:id]] = true
          pl[:instalments] << nxt
        end
      end
      remaining = pl[:charge] - pl[:instalments].sum { |i| i[:amount] }
      next unless remaining > DUST

      lump = loans.find { |x| !taken[x[:id]] && (x[:amount] - remaining).abs <= DUST && x[:date] >= pl[:instalments].map { |i| i[:date] }.max }
      if lump
        taken[lump[:id]] = true
        pl[:instalments] << lump
      end
    end

    # remainders that a unique set of later loan debits and seller refunds clears
    plans.each do |pl|
      remaining = (pl[:charge] - pl[:instalments].sum { |i| i[:amount] }).round(2)
      next unless remaining > DUST

      pool = loans.reject { |x| taken[x[:id]] }.select { |x| (x[:date] - pl[:date]).to_i.between?(LATER_WINDOW.first, 75) }.map { |x| [ :loan, x ] } +
        refunds.reject { |x| taken[x[:id]] }.select { |x| (x[:date] - pl[:date]).to_i.between?(1, REFUND_WINDOW_DAYS) }.map { |x| [ :refund, x ] }
      next if pool.size > 22

      hits = []
      (1..[ pool.size, 7 ].min).each do |k|
        pool.combination(k) { |c| hits << c if (c.sum { |_, x| x[:amount] } - remaining).abs <= 0.05 && c.any? { |t, _| t == :loan } }
      end
      next unless hits.one?

      hits.first.each do |kind, x|
        taken[x[:id]] = true
        kind == :loan ? pl[:instalments] << x : pl[:credits] << x
      end
    end

    plans.each { |pl| pl[:owed] = (pl[:charge] - pl[:instalments].sum { |i| i[:amount] } - pl[:credits].sum { |c| c[:amount] }).round(2) }
    # Open balance is only believable when the plan is a single purchase whose remainder is
    # whole instalments (the next ones still to come). An unexplained gap in a checkout stays
    # out of the card: its rows remain as they are and are listed for review.
    plans.each do |pl|
      unit = pl[:instalments].first[:amount]
      pl[:resolved] = pl[:owed].abs <= DUST || (!pl[:multi] && [ 1, 2 ].any? { |k| (pl[:owed] - k * unit).abs <= DUST })
    end
    { plans: plans.select { |pl| pl[:resolved] }, unresolved: plans.reject { |pl| pl[:resolved] }, parked: loans.reject { |l| taken[l[:id]] } }
  end

  def self.apply(family, wallet, card, plans)
    created = 0

    plans.each do |pl|
      key = "pay_in_3:#{pl[:purchases].map { |p| p[:id] }.min}"
      next if card.entries.exists?(source: "pay_in_3", external_id: "#{key}:charge")

      Account.transaction do
        add = lambda do |suffix, date, amount, name|
          card.entries.create!(source: "pay_in_3", external_id: "#{key}:#{suffix}", date: date, amount: amount, currency: "GBP", name: name,
                               entryable: Transaction.new(kind: "funds_movement", extra: { "pay_in_3_plan" => key }))
        end

        add.call("charge", pl[:date], pl[:charge], "Pay in 3: #{pl[:merchant]}")
        pl[:instalments].each do |i|
          inflow = add.call("inst:#{i[:id]}", i[:date], -i[:amount], "Pay in 3 instalment: #{pl[:merchant]}")
          outflow = i[:entry].entryable
          transfer = Transfer.new(inflow_transaction: inflow.entryable, outflow_transaction: outflow, status: "confirmed")
          transfer.save!
          inflow.entryable.update!(kind: "funds_movement")
          outflow.update!(kind: Transfer.kind_for_account(card, from_account: wallet), extra: outflow.extra.merge("pay_in_3_plan" => key))
        end
        pl[:credits].each { |c| add.call("credit:#{c[:id]}", c[:date], -c[:amount], "Pay in 3 seller refund: #{pl[:merchant]}") }
        pl[:purchases].each { |p| p[:entry].entryable.update!(extra: p[:entry].entryable.extra.merge("pay_in_3_plan" => key)) }
      end
      created += 1
    end

    card.sync_later if created > 0
    created
  end

  private

    # One hash per raw wallet row that has a stored entry.
    def pay_in_3_rows(wallet)
      provider = AccountProvider.find_by(account_id: wallet.id)&.provider
      raw = provider.respond_to?(:raw_transactions_payload) ? provider.raw_transactions_payload : nil
      raw = JSON.parse(raw) if raw.is_a?(String)
      return [] if raw.blank?

      entries = wallet.entries.where(source: "enable_banking").index_by(&:external_id)
      raw.filter_map do |t|
        data = t.with_indifferent_access
        entry = entries[EnableBankingEntry::Processor.compute_external_id(data)]
        next unless entry

        {
          id: entry.external_id, entry: entry, date: entry.date, amount: data.dig(:transaction_amount, :amount).to_d.to_f.abs,
          currency: data.dig(:transaction_amount, :currency), dir: data[:credit_debit_indicator],
          code: data.dig(:bank_transaction_code, :sub_code), merchant: data.dig(:creditor, :name).to_s.downcase.strip
        }
      end
    end
end
