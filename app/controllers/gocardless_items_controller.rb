# frozen_string_literal: true

class GocardlessItemsController < ApplicationController
  ALLOWED_ACCOUNTABLE_TYPES = %w[Depository CreditCard Investment Loan OtherAsset OtherLiability Crypto Property Vehicle].freeze

  before_action :set_gocardless_item, only: [ :show, :edit, :update, :destroy, :sync, :setup_accounts, :complete_account_setup, :callback, :reconnect ]

  def index
    @gocardless_items = Current.family.gocardless_items.ordered
  end

  def show
  end

  def new
    @gocardless_item = Current.family.gocardless_items.build
  end

  def edit
  end

  def create
    @gocardless_item = Current.family.gocardless_items.build(gocardless_item_params)
    @gocardless_item.name ||= "Gocardless Connection"

    if @gocardless_item.save
      redirect_to settings_providers_path, notice: t(".success"), status: :see_other
    else
      render_provider_panel("gocardless", alert: @gocardless_item.errors.full_messages.join(", "))
    end
  end

  # Start the bank consent flow: one item per bank (a GoCardless requisition).
  # Credentials are copied from an existing item, or read from the environment.
  def connect
    credentials = family_credentials
    unless credentials
      redirect_to settings_providers_path, alert: t(".no_credentials"), status: :see_other
      return
    end

    institution_id = params.require(:institution_id).to_s
    item = Current.family.gocardless_items.build(
      name: params[:name].presence || institution_id.split("_").first.titleize,
      secret_id: credentials[:secret_id], secret_key: credentials[:secret_key]
    )
    item.save!
    start_consent!(item, institution_id)
  rescue Provider::Gocardless::Error => e
    item&.destroy if item&.persisted? && item.requisition_id.blank?
    redirect_to settings_providers_path, alert: t(".failed", error: e.message), status: :see_other
  end

  # Consents last 90 days: this issues a fresh one for the same bank and keeps the accounts.
  def reconnect
    institution_id = @gocardless_item.institution_id.presence || params.require(:institution_id).to_s
    start_consent!(@gocardless_item, institution_id)
  rescue Provider::Gocardless::Error => e
    redirect_to settings_providers_path, alert: t(".failed", error: e.message), status: :see_other
  end

  # The bank sends the user back here after they approve.
  def callback
    requisition = @gocardless_item.gocardless_provider.requisition(@gocardless_item.requisition_id)

    if requisition[:status] == "LN"
      @gocardless_item.update!(status: :good, consent_expires_at: 90.days.from_now)
      @gocardless_item.sync_later unless @gocardless_item.syncing?
      redirect_to setup_accounts_gocardless_item_path(@gocardless_item), status: :see_other
    else
      redirect_to settings_providers_path, alert: t(".not_linked", status: requisition[:status]), status: :see_other
    end
  rescue Provider::Gocardless::Error => e
    redirect_to settings_providers_path, alert: t(".failed", error: e.message), status: :see_other
  end

  def update
    if @gocardless_item.update(gocardless_item_params)
      render_provider_panel("gocardless", notice: t(".success"))
    else
      render_provider_panel("gocardless", alert: @gocardless_item.errors.full_messages.join(", "))
    end
  end

  def destroy
    @gocardless_item.destroy_later
    redirect_to settings_providers_path, notice: t(".success", default: "Scheduled Gocardless connection for deletion.")
  end

  def sync
    unless @gocardless_item.syncing?
      @gocardless_item.sync_later
    end

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  # Collection actions for account linking flow

  def preload_accounts
    # Trigger a sync to fetch accounts from the provider
    gocardless_item = Current.family.gocardless_items.first
    unless gocardless_item&.credentials_configured?
      frame_redirect_to settings_providers_path, alert: t(".no_credentials_configured")
      return
    end

    gocardless_item.sync_later unless gocardless_item.syncing?
    redirect_to select_accounts_gocardless_items_path(accountable_type: params[:accountable_type], return_to: params[:return_to])
  end

  def select_accounts
    @accountable_type = params[:accountable_type]
    @return_to = params[:return_to]

    gocardless_item = Current.family.gocardless_items.first
    unless gocardless_item&.credentials_configured?
      frame_redirect_to settings_providers_path, alert: t(".no_credentials_configured")
      return
    end

    @gocardless_accounts = gocardless_item.gocardless_accounts
                                                .left_joins(:account_provider)
                                                .where(account_providers: { id: nil })
                                                .order(:name)
  end

  def link_accounts
    gocardless_item = Current.family.gocardless_items.first
    unless gocardless_item&.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_api_key")
      return
    end

    selected_ids = params[:selected_account_ids] || []
    if selected_ids.empty?
      redirect_to select_accounts_gocardless_items_path, alert: t(".no_accounts_selected")
      return
    end

    accountable_type = params[:accountable_type] || "Depository"
    created_count = 0
    already_linked_count = 0
    invalid_count = 0

    gocardless_item.gocardless_accounts.where(id: selected_ids).find_each do |gocardless_account|
      # Skip if already linked
      if gocardless_account.account_provider.present?
        already_linked_count += 1
        next
      end

      # Skip if invalid name
      if gocardless_account.name.blank?
        invalid_count += 1
        next
      end

      # Create Sure account and link
      link_gocardless_account(gocardless_account, accountable_type)
      created_count += 1
    rescue => e
      Rails.logger.error "GocardlessItemsController#link_accounts - Failed to link account: #{e.message}"
    end

    if created_count > 0
      gocardless_item.sync_later unless gocardless_item.syncing?
      redirect_to accounts_path, notice: t(".success", count: created_count)
    else
      redirect_to select_accounts_gocardless_items_path, alert: t(".link_failed")
    end
  end

  def select_existing_account
    @account = Current.family.accounts.find(params[:account_id])
    @gocardless_item = Current.family.gocardless_items.first

    unless @gocardless_item&.credentials_configured?
      frame_redirect_to settings_providers_path, alert: t(".no_credentials_configured")
      return
    end

    @gocardless_accounts = @gocardless_item.gocardless_accounts
                                                      .left_joins(:account_provider)
                                                      .where(account_providers: { id: nil })
                                                      .order(:name)
  end

  def link_existing_account
    account = Current.family.accounts.find(params[:account_id])
    gocardless_item = Current.family.gocardless_items.first

    unless gocardless_item&.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_api_key")
      return
    end

    gocardless_account = gocardless_item.gocardless_accounts.find(params[:gocardless_account_id])

    if gocardless_account.account_provider.present?
      redirect_to account_path(account), alert: t(".provider_account_already_linked")
      return
    end

    gocardless_account.ensure_account_provider!(account)
    gocardless_item.sync_later unless gocardless_item.syncing?

    redirect_to account_path(account), notice: t(".success", account_name: account.name)
  end

  def setup_accounts
    @unlinked_accounts = @gocardless_item.unlinked_gocardless_accounts.order(:name)

    if @unlinked_accounts.empty?
      redirect_to accounts_path, notice: t(".all_accounts_linked")
    end
  end

  def complete_account_setup
    # The setup screen posts the ticked accounts as selected_accounts[]; richer clients
    # may post an accounts hash with per-account type/subtype instead.
    account_configs = params[:accounts].presence || selected_account_configs

    if account_configs.empty?
      redirect_to setup_accounts_gocardless_item_path(@gocardless_item), alert: t(".no_accounts")
      return
    end

    created_count = 0
    skipped_count = 0

    account_configs.each do |gocardless_account_id, config|
      next if config[:account_type] == "skip"

      gocardless_account = @gocardless_item.gocardless_accounts.find_by(id: gocardless_account_id)
      next unless gocardless_account
      next if gocardless_account.account_provider.present?

      accountable_type = infer_accountable_type(config[:account_type], config[:subtype])
      account = create_account_from_gocardless(gocardless_account, accountable_type, config)

      if account&.persisted?
        gocardless_account.ensure_account_provider!(account)
        gocardless_account.update!(sync_start_date: config[:sync_start_date]) if config[:sync_start_date].present?
        created_count += 1
      else
        skipped_count += 1
      end
    rescue => e
      Rails.logger.error "GocardlessItemsController#complete_account_setup - Error: #{e.message}"
      skipped_count += 1
    end

    if created_count > 0
      @gocardless_item.sync_later unless @gocardless_item.syncing?
      redirect_to accounts_path, notice: t(".success", count: created_count)
    elsif skipped_count > 0 && created_count == 0
      redirect_to accounts_path, notice: t(".all_skipped")
    else
      redirect_to setup_accounts_gocardless_item_path(@gocardless_item), alert: t(".creation_failed", error: "Unknown error")
    end
  end

  private

    # Ticked accounts become checking or savings accounts, following the bank's own label.
    def selected_account_configs
      Array(params[:selected_accounts]).index_with do |id|
        bank_type = @gocardless_item.gocardless_accounts.find_by(id: id)&.account_type.to_s.downcase
        { account_type: "depository", subtype: bank_type.include?("sv") || bank_type.include?("sav") ? "savings" : "checking" }
      end
    end

    def family_credentials
      existing = Current.family.gocardless_items.where.not(secret_id: [ nil, "" ]).first
      return { secret_id: existing.secret_id, secret_key: existing.secret_key } if existing&.credentials_configured?
      return nil if ENV["GOCARDLESS_SECRET_ID"].blank? || ENV["GOCARDLESS_SECRET_KEY"].blank?
      { secret_id: ENV["GOCARDLESS_SECRET_ID"], secret_key: ENV["GOCARDLESS_SECRET_KEY"] }
    end

    def start_consent!(item, institution_id)
      requisition = item.gocardless_provider.create_requisition(
        institution_id: institution_id,
        redirect: callback_gocardless_item_url(item),
        reference: "sure-#{item.id}-#{Time.current.to_i}",
        max_historical_days: item.max_historical_days
      )
      item.update!(requisition_id: requisition[:id], institution_id: institution_id)
      redirect_to requisition[:link], allow_other_host: true, status: :see_other
    end

    def set_gocardless_item
      @gocardless_item = Current.family.gocardless_items.find(params[:id])
    end

    def gocardless_item_params
      params.require(:gocardless_item).permit(
        :name,
        :sync_start_date,
        :secret_id,
        :secret_key
      )
    end

    def link_gocardless_account(gocardless_account, accountable_type)
      accountable_class = validated_accountable_class(accountable_type)

      account = Current.family.accounts.create!(
        name: gocardless_account.name,
        balance: gocardless_account.current_balance || 0,
        currency: gocardless_account.currency || "USD",
        accountable: accountable_class.new
      )

      gocardless_account.ensure_account_provider!(account)
      account
    end

    def create_account_from_gocardless(gocardless_account, accountable_type, config)
      accountable_class = validated_accountable_class(accountable_type)
      accountable_attrs = {}

      # Set subtype if the accountable supports it
      if config[:subtype].present? && accountable_class.const_defined?(:SUBTYPES)
        accountable_attrs[:subtype] = config[:subtype]
      end

      Current.family.accounts.create!(
        name: gocardless_account.name,
        balance: config[:balance].present? ? config[:balance].to_d : (gocardless_account.current_balance || 0),
        currency: gocardless_account.currency || "USD",
        accountable: accountable_class.new(accountable_attrs)
      )
    end

    def infer_accountable_type(account_type, subtype = nil)
      case account_type&.downcase
      when "depository"
        "Depository"
      when "credit_card"
        "CreditCard"
      when "investment"
        "Investment"
      when "loan"
        "Loan"
      when "other_asset"
        "OtherAsset"
      when "other_liability"
        "OtherLiability"
      when "crypto"
        "Crypto"
      when "property"
        "Property"
      when "vehicle"
        "Vehicle"
      else
        "Depository"
      end
    end

    def validated_accountable_class(accountable_type)
      unless ALLOWED_ACCOUNTABLE_TYPES.include?(accountable_type)
        raise ArgumentError, "Invalid accountable type: #{accountable_type}"
      end

      accountable_type.constantize
    end
end
