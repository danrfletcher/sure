# frozen_string_literal: true

# GoCardless Bank Account Data (formerly Nordigen) client. Read-only: it lists
# institutions, creates and reads requisitions (bank consents) and reads
# account details, balances and booked transactions.
#
# Tokens are cached by the caller: pass the stored `tokens` hash in and persist
# what `on_tokens_changed` yields, so a sync does not mint a new token pair
# every time.
class Provider::Gocardless
  include HTTParty

  BASE_URL = "https://bankaccountdata.gocardless.com/api/v2"

  headers "User-Agent" => "Sure Finance Gocardless Client"
  default_options.merge!(verify: true, ssl_verify_mode: OpenSSL::SSL::VERIFY_PEER, timeout: 60)

  class Error < StandardError
    attr_reader :error_type

    def initialize(message, error_type = :unknown)
      super(message)
      @error_type = error_type
    end
  end

  class ConfigurationError < Error; end
  class AuthenticationError < Error; end
  # One account on a linked bank is closed or deleted (e.g. a Revolut vault). The bank's
  # consent is fine, so this must not be treated as a login failure.
  class AccountInactiveError < Error; end
  class RateLimitedError < Error; end
  # The bank consent (requisition) has expired or been revoked: the user must re-link.
  class ConsentExpiredError < Error; end

  attr_reader :secret_id, :secret_key, :tokens

  # tokens: { access:, access_expires_at:, refresh:, refresh_expires_at: } (Time values)
  def initialize(secret_id:, secret_key:, tokens: {}, on_tokens_changed: nil)
    @secret_id = secret_id
    @secret_key = secret_key
    @tokens = (tokens || {}).symbolize_keys
    @on_tokens_changed = on_tokens_changed
    validate_configuration!
  end

  def institutions(country: "gb")
    get("/institutions/", query: { country: country })
  end

  def create_requisition(institution_id:, redirect:, reference:, max_historical_days: 730, access_valid_for_days: 90)
    agreement = post("/agreements/enduser/", body: {
      institution_id: institution_id,
      max_historical_days: max_historical_days,
      access_valid_for_days: access_valid_for_days,
      access_scope: %w[balances details transactions]
    })
    post("/requisitions/", body: {
      institution_id: institution_id,
      redirect: redirect,
      reference: reference,
      agreement: agreement[:id]
    })
  end

  def requisition(id)
    get("/requisitions/#{id}/")
  end

  def account_details(account_id)
    get("/accounts/#{account_id}/details/")
  end

  def account_balances(account_id)
    get("/accounts/#{account_id}/balances/")
  end

  def account_transactions(account_id, date_from: nil, date_to: nil)
    query = { date_from: date_from&.to_date&.iso8601, date_to: date_to&.to_date&.iso8601 }.compact
    get("/accounts/#{account_id}/transactions/", query: query)
  end

  private

    RETRYABLE_ERRORS = [
      SocketError, Net::OpenTimeout, Net::ReadTimeout,
      Errno::ECONNRESET, Errno::ECONNREFUSED, Errno::ETIMEDOUT, EOFError
    ].freeze

    MAX_RETRIES = 3
    INITIAL_RETRY_DELAY = 2 # seconds

    def validate_configuration!
      raise ConfigurationError, "Secret ID is required" if @secret_id.blank?
      raise ConfigurationError, "Secret key is required" if @secret_key.blank?
    end

    def get(path, query: nil)
      request(:get, path, query: query)
    end

    def post(path, body:)
      request(:post, path, body: body.to_json)
    end

    def request(verb, path, query: nil, body: nil, authenticated: true)
      with_retries("#{verb} #{path}") do
        options = { headers: headers(authenticated: authenticated) }
        options[:query] = query if query
        options[:body] = body if body
        handle_response(self.class.public_send(verb, "#{BASE_URL}#{path}", options))
      end
    end

    def headers(authenticated: true)
      h = { "Content-Type" => "application/json", "Accept" => "application/json" }
      h["Authorization"] = "Bearer #{access_token}" if authenticated
      h
    end

    def access_token
      now = Time.current
      return tokens[:access] if tokens[:access].present? && tokens[:access_expires_at].present? && tokens[:access_expires_at] > now + 60.seconds

      if tokens[:refresh].present? && tokens[:refresh_expires_at].present? && tokens[:refresh_expires_at] > now + 60.seconds
        response = request(:post, "/token/refresh/", body: { refresh: tokens[:refresh] }.to_json, authenticated: false)
        @tokens = tokens.merge(access: response[:access], access_expires_at: now + response[:access_expires].to_i.seconds)
      else
        response = request(:post, "/token/new/", body: { secret_id: secret_id, secret_key: secret_key }.to_json, authenticated: false)
        @tokens = {
          access: response[:access], access_expires_at: now + response[:access_expires].to_i.seconds,
          refresh: response[:refresh], refresh_expires_at: now + response[:refresh_expires].to_i.seconds
        }
      end

      @on_tokens_changed&.call(@tokens)
      tokens[:access]
    end

    def with_retries(operation_name, max_retries: MAX_RETRIES)
      retries = 0

      begin
        yield
      rescue *RETRYABLE_ERRORS => e
        retries += 1

        if retries <= max_retries
          delay = calculate_retry_delay(retries)
          Rails.logger.warn(
            "Gocardless API: #{operation_name} failed (attempt #{retries}/#{max_retries}): " \
            "#{e.class}: #{e.message}. Retrying in #{delay}s..."
          )
          sleep(delay)
          retry
        else
          raise Error.new("Network error after #{max_retries} retries: #{e.message}", :network_error)
        end
      end
    end

    def calculate_retry_delay(retry_count)
      base_delay = INITIAL_RETRY_DELAY * (2 ** (retry_count - 1))
      jitter = base_delay * rand * 0.25
      [ base_delay + jitter, 30 ].min
    end

    def handle_response(response)
      case response.code
      when 200, 201
        JSON.parse(response.body, symbolize_names: true)
      when 400
        raise Error.new("Bad request: #{summary(response)}", :bad_request)
      when 401
        if response.body.to_s.include?("AccountInactiveError")
          raise AccountInactiveError.new("Account is deactivated or no longer exists", :account_inactive)
        end

        raise AuthenticationError.new("Invalid GoCardless credentials or token", :unauthorized)
      when 403
        raise AuthenticationError.new("Access forbidden: #{summary(response)}", :access_forbidden)
      when 404
        raise Error.new("Resource not found", :not_found)
      when 409
        # GoCardless answers 409 when the requisition's consent is no longer usable
        raise ConsentExpiredError.new("Bank consent is no longer valid: #{summary(response)}", :consent_expired)
      when 429
        raise RateLimitedError.new("Bank rate limit reached. Try again later.", :rate_limited)
      when 500..599
        raise Error.new("GoCardless server error (#{response.code})", :server_error)
      else
        raise Error.new("Unexpected response #{response.code}: #{summary(response)}", :unknown)
      end
    end

    # Error bodies carry a summary and detail only; never echo the raw body.
    def summary(response)
      parsed = JSON.parse(response.body, symbolize_names: true)
      [ parsed[:summary], parsed[:detail] ].compact.join(" - ").presence || "no detail"
    rescue JSON::ParserError
      "no detail"
    end
end
