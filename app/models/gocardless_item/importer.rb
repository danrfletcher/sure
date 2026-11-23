# frozen_string_literal: true

class GocardlessItem::Importer
  include SyncStats::Collector
  include GocardlessAccount::DataHelpers

  attr_reader :gocardless_item, :gocardless_provider, :sync

  def initialize(gocardless_item, gocardless_provider:, sync: nil)
    @gocardless_item = gocardless_item
    @gocardless_provider = gocardless_provider
    @sync = sync
  end

  class CredentialsError < StandardError; end

  def import
    Rails.logger.info "GocardlessItem::Importer - Starting import for item #{gocardless_item.id}"

    credentials = gocardless_item.gocardless_credentials
    unless credentials
      raise CredentialsError, "No Gocardless credentials configured for item #{gocardless_item.id}"
    end

    # Step 1: Fetch and store all accounts
    import_accounts(credentials)

    # Step 2: For LINKED accounts only, fetch data
    # Unlinked accounts just need basic info (name, balance) for the setup modal
    linked_accounts = GocardlessAccount
      .where(gocardless_item_id: gocardless_item.id)
      .joins(:account_provider)

    Rails.logger.info "GocardlessItem::Importer - Found #{linked_accounts.count} linked accounts to process"

    linked_accounts.each do |gocardless_account|
      Rails.logger.info "GocardlessItem::Importer - Processing linked account #{gocardless_account.id}"
      import_account_data(gocardless_account, credentials)
    end

    gocardless_item.disambiguate_account_names!

    # Update raw payload on the item
    gocardless_item.upsert_gocardless_snapshot!(stats)
  rescue Provider::Gocardless::AuthenticationError => e
    gocardless_item.update!(status: :requires_update)
    raise
  end

  private

    def stats
      @stats ||= {}
    end

    def persist_stats!
      return unless sync&.respond_to?(:sync_stats)
      merged = (sync.sync_stats || {}).merge(stats)
      sync.update_columns(sync_stats: merged)
    end

    def import_accounts(credentials)
      Rails.logger.info "GocardlessItem::Importer - Fetching accounts"

      requisition = gocardless_provider.requisition(gocardless_item.requisition_id)
      stats["api_requests"] = stats.fetch("api_requests", 0) + 1

      # LN = linked. Anything else (expired, rejected, suspended) means the consent is gone.
      unless requisition[:status] == "LN"
        gocardless_item.update!(status: :requires_update)
        raise Provider::Gocardless::ConsentExpiredError.new("Bank consent is #{requisition[:status]}", :consent_expired)
      end

      account_ids = Array(requisition[:accounts])
      stats["total_accounts"] = account_ids.size

      # Track upstream account IDs to detect removed accounts
      upstream_account_ids = []

      account_ids.each do |account_id|
        begin
          # Details and balances are rate limited too, so an account already known is
          # refreshed later (throttled) in import_account_data.
          existing = gocardless_item.gocardless_accounts.find_by(gocardless_account_id: account_id.to_s)
          upstream_account_ids << account_id.to_s
          next if existing

          account_data = {
            id: account_id,
            details: gocardless_provider.account_details(account_id)[:account],
            balances: gocardless_provider.account_balances(account_id)[:balances]
          }
          stats["api_requests"] += 2
          import_account(account_data, credentials)
        rescue Provider::Gocardless::ConsentExpiredError, Provider::Gocardless::AuthenticationError
          raise
        rescue => e
          Rails.logger.error "GocardlessItem::Importer - Failed to import account: #{e.message}"
          stats["accounts_skipped"] = stats.fetch("accounts_skipped", 0) + 1
          register_error(e, account_data: account_data)
        end
      end

      persist_stats!

      # Clean up accounts that no longer exist upstream
      prune_removed_accounts(upstream_account_ids)
    end

    def import_account(account_data, credentials)
      gocardless_account_id = account_data[:id].to_s
      return if gocardless_account_id.blank?

      gocardless_account = gocardless_item.gocardless_accounts.find_or_initialize_by(
        gocardless_account_id: gocardless_account_id
      )
      gocardless_account.upsert_from_gocardless!(account_data)

      stats["accounts_imported"] = stats.fetch("accounts_imported", 0) + 1
    end

    # Banks allow about four reads a day per account. Opening the app and the
    # scheduled sync both trigger this, so an account pulled recently is skipped.
    MIN_PULL_INTERVAL = 6.hours

    def import_account_data(gocardless_account, credentials)
      last = gocardless_account.last_pulled_at
      if last.present? && last > MIN_PULL_INTERVAL.ago && !force_pull?
        stats["accounts_throttled"] = stats.fetch("accounts_throttled", 0) + 1
        return
      end

      refresh_balance(gocardless_account)
      import_transactions(gocardless_account, credentials)
      gocardless_account.update_columns(last_pulled_at: Time.current)
    end

    def force_pull?
      ENV["GOCARDLESS_FORCE_PULL"].present?
    end

    def refresh_balance(gocardless_account)
      balances = gocardless_provider.account_balances(gocardless_account.gocardless_account_id)
      stats["api_requests"] = stats.fetch("api_requests", 0) + 1
      gocardless_account.update!(current_balance: gocardless_account.pick_balance(balances[:balances]))
      write_raw_backup(gocardless_account, "balances", balances)
    rescue Provider::Gocardless::ConsentExpiredError, Provider::Gocardless::AuthenticationError
      raise
    rescue => e
      register_error(e, context: "balances", account_id: gocardless_account.id)
    end

    # Raw responses are kept on disk as a replayable backup, separate from Sure's own database.
    def write_raw_backup(gocardless_account, kind, payload)
      dir = gocardless_item.raw_backup_dir
      return if dir.blank?
      FileUtils.mkdir_p(dir)
      path = File.join(dir, "#{gocardless_account.gocardless_account_id}.#{kind}.json")
      File.write(path, JSON.pretty_generate(payload))
      File.chmod(0o600, path)
    rescue => e
      Rails.logger.warn "GocardlessItem::Importer - raw backup not written: #{e.class}"
    end

    # GoCardless amounts are strings, negative for money out. Keep that convention
    # here and let the processor flip it to Sure's (positive = out).
    def normalize_transaction(t)
      amount = t.dig(:transactionAmount, :amount)
      outgoing = amount.to_s.start_with?("-")
      counterparty = (outgoing ? t[:creditorName] : t[:debtorName]).presence || t[:creditorName].presence || t[:debtorName].presence
      remittance = t[:remittanceInformationUnstructured].presence || Array(t[:remittanceInformationUnstructuredArray]).join(" ").presence
      {
        id: (t[:transactionId].presence || t[:internalTransactionId]).to_s,
        date: t[:bookingDate].presence || t[:valueDate],
        amount: amount,
        currency: t.dig(:transactionAmount, :currency),
        name: counterparty || remittance || "Transaction",
        merchant_name: counterparty,
        description: remittance
      }
    end

    def import_transactions(gocardless_account, credentials)
      Rails.logger.info "GocardlessItem::Importer - Fetching transactions for account #{gocardless_account.id}"

      begin
        # Determine date range
        start_date = calculate_transaction_start_date(gocardless_account)
        end_date = Date.current

        response = gocardless_provider.account_transactions(
          gocardless_account.gocardless_account_id,
          date_from: start_date,
          date_to: end_date
        )
        stats["api_requests"] = stats.fetch("api_requests", 0) + 1
        write_raw_backup(gocardless_account, "transactions", response)

        # Booked only: pending entries get new ids when they settle and would duplicate.
        booked = Array(response.dig(:transactions, :booked))
        transactions_data = booked.map { |t| normalize_transaction(t) }.reject { |t| t[:id].blank? }

        if transactions_data.any?
          # Convert SDK objects to hashes and merge with existing
          transactions_hashes = transactions_data.map { |t| sdk_object_to_hash(t) }
          merged = merge_transactions(gocardless_account.raw_transactions_payload || [], transactions_hashes)
          gocardless_account.upsert_gocardless_transactions_snapshot!(merged)
          stats["transactions_found"] = stats.fetch("transactions_found", 0) + transactions_data.size
        end
      rescue Provider::Gocardless::ConsentExpiredError, Provider::Gocardless::AuthenticationError
        raise
      rescue => e
        Rails.logger.warn "GocardlessItem::Importer - Failed to fetch transactions: #{e.message}"
        register_error(e, context: "transactions", account_id: gocardless_account.id)
      end
    end

    def calculate_transaction_start_date(gocardless_account)
      # Use user-specified start date if available
      user_start = gocardless_account.sync_start_date
      return user_start if user_start.present?

      # For accounts with existing transactions, use incremental sync
      if gocardless_account.last_pulled_at.present?
        # Incremental: go back 7 days from the last pull to catch late-booked entries
        (gocardless_account.last_pulled_at - 7.days).to_date
      else
        # First pull: as much history as the consent allows
        gocardless_item.max_historical_days.days.ago.to_date
      end
    end

    def merge_transactions(existing, new_transactions)
      # Merge by ID, preferring newer data
      by_id = {}
      existing.each { |t| by_id[transaction_key(t)] = t }
      new_transactions.each { |t| by_id[transaction_key(t)] = t }
      by_id.values
    end

    def transaction_key(transaction)
      transaction = transaction.with_indifferent_access if transaction.is_a?(Hash)
      # Use ID if available, otherwise generate key from date/amount/description
      transaction[:id] || transaction["id"] ||
        [ transaction[:date], transaction[:amount], transaction[:description] ].join("-")
    end

    def prune_removed_accounts(upstream_account_ids)
      return if upstream_account_ids.empty?

      # Find accounts that exist locally but not upstream
      removed = gocardless_item.gocardless_accounts
        .where.not(gocardless_account_id: upstream_account_ids)

      if removed.any?
        Rails.logger.info "GocardlessItem::Importer - Pruning #{removed.count} removed accounts"
        removed.destroy_all
      end
    end

    def register_error(error, **context)
      stats["errors"] ||= []
      stats["errors"] << {
        message: error.message,
        context: context.to_s,
        timestamp: Time.current.iso8601
      }
    end
end
