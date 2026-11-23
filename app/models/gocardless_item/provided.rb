# frozen_string_literal: true

module GocardlessItem::Provided
  extend ActiveSupport::Concern

  def gocardless_provider
    return nil unless credentials_configured?

    Provider::Gocardless.new(
      secret_id: secret_id,
      secret_key: secret_key,
      tokens: {
        access: access_token, access_expires_at: access_expires_at,
        refresh: refresh_token, refresh_expires_at: refresh_expires_at
      },
      on_tokens_changed: ->(t) {
        update_columns(
          access_token: t[:access], access_expires_at: t[:access_expires_at],
          refresh_token: t[:refresh], refresh_expires_at: t[:refresh_expires_at]
        )
      }
    )
  end

  # Returns credentials hash for API calls that need them passed explicitly
  def gocardless_credentials
    return nil unless credentials_configured?

    {
      secret_id: secret_id,
      secret_key: secret_key
    }
  end
end
