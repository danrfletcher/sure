# frozen_string_literal: true

class GocardlessAccount < ApplicationRecord
  include CurrencyNormalizable, Encryptable
  include GocardlessAccount::DataHelpers

  # Encrypt raw provider payloads if ActiveRecord encryption is configured
  if encryption_ready?
    encrypts :raw_payload
    encrypts :raw_transactions_payload
  end

  belongs_to :gocardless_item

  # Association through account_providers
  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account
  has_one :linked_account, through: :account_provider, source: :account

  validates :name, :currency, presence: true

  # Scopes
  scope :with_linked, -> { joins(:account_provider) }
  scope :without_linked, -> { left_joins(:account_provider).where(account_providers: { id: nil }) }
  scope :ordered, -> { order(created_at: :desc) }

  # Callbacks
  after_destroy :enqueue_connection_cleanup

  # Helper to get account using account_providers system
  def current_account
    account
  end

  # Idempotently create or update AccountProvider link
  # CRITICAL: After creation, reload association to avoid stale nil
  def ensure_account_provider!(linked_account)
    return nil unless linked_account

    provider = account_provider || build_account_provider
    provider.account = linked_account
    provider.save!

    # Reload to clear cached nil value
    reload_account_provider
    account_provider
  end

  def upsert_from_gocardless!(account_data)
    # Convert SDK object to hash if needed
    data = sdk_object_to_hash(account_data).with_indifferent_access

    # `account_data` is { id:, details: <GoCardless account object>, balances: [..] }.
    details = (data[:details] || {}).with_indifferent_access
    update!(
      gocardless_account_id: data[:id].to_s,
      name: details[:name].presence || details[:product].presence || details[:ownerName].presence || "Account #{data[:id].to_s.first(6)}",
      current_balance: pick_balance(data[:balances]),
      currency: extract_currency(details, fallback: "GBP"),
      account_status: details[:status],
      account_type: details[:cashAccountType] || details[:product],
      provider: data[:provider] || data[:brokerage_name],
      institution_metadata: extract_institution_metadata(data),
      raw_payload: account_data
    )
  end

  def upsert_gocardless_transactions_snapshot!(transactions_snapshot)
    assign_attributes(
      raw_transactions_payload: transactions_snapshot
    )

    save!
  end

  # Pick the figure that matches what the bank's app shows. GoCardless returns several
  # balance types; prefer the interim/closing booked balance over forecasts.
  BALANCE_PREFERENCE = %w[interimAvailable interimBooked closingBooked expected openingBooked].freeze

  # Cards report "available" as the unused credit limit, which is not what is owed.
  CARD_BALANCE_PREFERENCE = %w[interimBooked closingBooked expected information interimAvailable openingBooked].freeze

  def pick_balance(balances)
    list = Array(balances).map { |b| b.with_indifferent_access }
    preference = account_type.to_s.casecmp?("card") ? CARD_BALANCE_PREFERENCE : BALANCE_PREFERENCE
    chosen = preference.lazy.filter_map { |type| list.find { |b| b[:balanceType] == type } }.first || list.first
    parse_decimal(chosen&.dig(:balanceAmount, :amount))
  end

  private

    def extract_institution_metadata(data)
      {
        name: data[:institution_name] || data.dig(:institution, :name),
        logo: data[:institution_logo] || data.dig(:institution, :logo),
        domain: data[:institution_domain] || data.dig(:institution, :domain)
      }.compact
    end

    def enqueue_connection_cleanup
      return unless gocardless_item

      GocardlessConnectionCleanupJob.perform_later(
        gocardless_item_id: gocardless_item.id,
        account_id: id
      )
    end

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' for Gocardless account #{id}, defaulting to USD")
    end
end
