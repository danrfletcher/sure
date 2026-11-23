# frozen_string_literal: true

# Accounts whose transactions the matcher must not link receipts to (e.g. a
# card whose receipts are handled some other way). Configured with
# Setting.receipt_excluded_accounts, a comma-separated list. Each entry matches
# an account by id, by exact name (ignoring case), or by the last digits of the
# mask / account number a connected provider reports for it.
class Receipt::ExcludedAccounts
  MASK_ATTRIBUTES = %i[mask account_number_mask account_number].freeze

  def initialize(family, setting: Setting.receipt_excluded_accounts)
    @family = family
    @tokens = setting.to_s.split(",").map(&:strip).reject(&:blank?)
  end

  def account_ids
    return [] if @tokens.empty?

    (ids_by_id_or_name + ids_by_provider_mask + ids_by_plaid_mask).uniq
  end

  private

    def ids_by_id_or_name
      uuids = @tokens.select { |token| token.match?(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/) }
      names = @tokens.map(&:downcase)

      @family.accounts.where(id: uuids).or(@family.accounts.where("LOWER(accounts.name) IN (?)", names)).pluck(:id)
    end

    def ids_by_provider_mask
      AccountProvider.where(account_id: @family.accounts.select(:id)).includes(:provider).filter_map do |account_provider|
        digits = MASK_ATTRIBUTES.filter_map { |attribute| provider_value(account_provider.provider, attribute) }
        account_provider.account_id if digits.any? { |value| @tokens.any? { |token| value.end_with?(token) } }
      end
    end

    # Plaid links sit on the account row itself rather than in account_providers.
    def ids_by_plaid_mask
      @family.accounts.joins(:plaid_account).pluck("accounts.id", "plaid_accounts.mask").filter_map do |account_id, mask|
        account_id if mask.present? && @tokens.any? { |token| mask.end_with?(token) }
      end
    end

    def provider_value(provider, attribute)
      provider.public_send(attribute).to_s.strip.presence if provider.respond_to?(attribute)
    end
end
