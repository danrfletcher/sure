module Family::PaypalCreditMatchable
  # Opt-in (PAY_IN_3_ACCOUNT is the wallet's account id, PAYPAL_CREDIT_CARD the card's; ids, not
  # names, so renaming either account never switches this off).
  #
  # A repayment of PayPal Credit leaves the wallet as a PAYPAL_CREDIT_PAYMENT row. Left alone
  # Sure counts it as spending on top of the purchase it repays. This turns each such row into
  # a transfer from the wallet to the credit-card account (the wallet-funding rule still
  # matches the bank payment that funds it), so the purchase stays the spending
  # and the card balance falls. The card must already exist: the feed carries no PayPal Credit
  # purchases, so its charges come from statements or receipts, never from this rule.
  #
  # With dry_run: true nothing is written and the wallet rows that would be linked are returned.
  def auto_match_paypal_credit!(dry_run: false)
    none = dry_run ? [] : 0
    wallet = account_from_env("PAY_IN_3_ACCOUNT")
    card = account_from_env("PAYPAL_CREDIT_CARD", type: "CreditCard")
    return none unless wallet && card

    rows = pay_in_3_rows(wallet).select { |r| r[:code] == "PAYPAL_CREDIT_PAYMENT" && r[:dir] == "DBIT" && r[:currency] == card.currency }
    todo = rows.reject { |r| card.entries.exists?(source: "paypal_credit", external_id: "paypal_credit:#{r[:id]}") }
    return todo if dry_run

    todo.each do |r|
      Account.transaction do
        inflow = card.entries.create!(source: "paypal_credit", external_id: "paypal_credit:#{r[:id]}", date: r[:date], amount: -r[:amount],
                                      currency: card.currency, name: "PayPal Credit payment",
                                      entryable: Transaction.new(kind: "funds_movement"))
        outflow = r[:entry].entryable
        Transfer.new(inflow_transaction: inflow.entryable, outflow_transaction: outflow, status: "confirmed").save!
        outflow.update!(kind: Transfer.kind_for_account(card, from_account: wallet), extra: outflow.extra.merge("pay_in_3_plan" => "paypal_credit"))
      end
    end

    card.sync_later if todo.any?
    todo.size
  end
end
