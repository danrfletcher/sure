# frozen_string_literal: true

class GocardlessAccount::Processor
  include GocardlessAccount::DataHelpers

  attr_reader :gocardless_account

  def initialize(gocardless_account)
    @gocardless_account = gocardless_account
  end

  def process
    account = gocardless_account.current_account
    return unless account

    Rails.logger.info "GocardlessAccount::Processor - Processing account #{gocardless_account.id} -> Sure account #{account.id}"

    anchor_balance = update_account_balance(account)

    # Process transactions
    transactions_count = gocardless_account.raw_transactions_payload&.size || 0
    Rails.logger.info "GocardlessAccount::Processor - Transactions payload has #{transactions_count} items"

    if gocardless_account.raw_transactions_payload.present?
      Rails.logger.info "GocardlessAccount::Processor - Processing transactions..."
      GocardlessAccount::Transactions::Processor.new(gocardless_account).process
    else
      Rails.logger.warn "GocardlessAccount::Processor - No transactions payload to process"
    end

    # Anchor the reported balance AFTER importing, never before. The anchor is judged
    # against the imported ledger, so the transactions for this sync must already be
    # persisted when it is written. See Account::CurrentBalanceManager.
    account.set_current_balance(anchor_balance) if anchor_balance

    # Trigger immediate UI refresh so entries appear in the activity feed
    account.broadcast_sync_complete
    Rails.logger.info "GocardlessAccount::Processor - Broadcast sync complete for account #{account.id}"

    { transactions_processed: transactions_count > 0 }
  end

  private

    def update_account_balance(account)
      # Get balance from provider data
      balance = gocardless_account.current_balance || 0

      # Banking sign convention:
      # - CreditCard and Loan accounts may need sign inversion
      # Provider returns negative for positive balance, so we negate it
      if account.accountable_type == "CreditCard" || account.accountable_type == "Loan"
        balance = -balance
      end

      Rails.logger.info "GocardlessAccount::Processor - Balance update: #{balance}"

      account.assign_attributes(
        balance: balance,
        cash_balance: balance,
        currency: gocardless_account.currency || account.currency
      )
      account.save!

      # Returned to `process`, which anchors it once the import is done.
      balance
    end
end
