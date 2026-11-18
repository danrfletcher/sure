# frozen_string_literal: true

require "test_helper"

class Provider::GocardlessTest < ActiveSupport::TestCase
  BASE = Provider::Gocardless::BASE_URL

  def json(body, status: 200)
    { status: status, body: body.to_json, headers: { "Content-Type" => "application/json" } }
  end

  test "mints a token once, then reuses the cached access token" do
    new_token = stub_request(:post, "#{BASE}/token/new/").to_return(json({ access: "A", access_expires: 86_400, refresh: "R", refresh_expires: 2_592_000 }))
    stub_request(:get, "#{BASE}/requisitions/r1/").with(headers: { "Authorization" => "Bearer A" }).to_return(json({ status: "LN" }))

    saved = nil
    provider = Provider::Gocardless.new(secret_id: "i", secret_key: "k", on_tokens_changed: ->(t) { saved = t })
    provider.requisition("r1")
    provider.requisition("r1")

    assert_requested new_token, times: 1
    assert_equal "R", saved[:refresh]
  end

  test "refreshes with the refresh token when only the access token has expired" do
    refresh = stub_request(:post, "#{BASE}/token/refresh/").with(body: { refresh: "R" }.to_json).to_return(json({ access: "A2", access_expires: 86_400 }))
    stub_request(:get, "#{BASE}/requisitions/r1/").with(headers: { "Authorization" => "Bearer A2" }).to_return(json({ status: "LN" }))

    provider = Provider::Gocardless.new(
      secret_id: "i", secret_key: "k",
      tokens: { access: "A", access_expires_at: 1.hour.ago, refresh: "R", refresh_expires_at: 10.days.from_now }
    )
    provider.requisition("r1")

    assert_requested refresh, times: 1
  end

  test "maps 409 to a consent error, 429 to rate limiting and 401 to authentication" do
    tokens = { access: "A", access_expires_at: 1.day.from_now }
    provider = Provider::Gocardless.new(secret_id: "i", secret_key: "k", tokens: tokens)

    stub_request(:get, "#{BASE}/accounts/a/transactions/").to_return(json({ summary: "Account suspended", detail: "x" }, status: 409))
    assert_raises(Provider::Gocardless::ConsentExpiredError) { provider.account_transactions("a") }

    stub_request(:get, "#{BASE}/accounts/b/transactions/").to_return(json({ summary: "Rate limit" }, status: 429))
    assert_raises(Provider::Gocardless::RateLimitedError) { provider.account_transactions("b") }

    stub_request(:get, "#{BASE}/accounts/c/transactions/").to_return(json({}, status: 401))
    assert_raises(Provider::Gocardless::AuthenticationError) { provider.account_transactions("c") }
  end

  test "error messages never contain the response body's other fields" do
    provider = Provider::Gocardless.new(secret_id: "i", secret_key: "k", tokens: { access: "A", access_expires_at: 1.day.from_now })
    stub_request(:get, "#{BASE}/requisitions/r/").to_return(json({ summary: "Bad", detail: "d", secret: "leak" }, status: 400))

    error = assert_raises(Provider::Gocardless::Error) { provider.requisition("r") }
    assert_no_match(/leak/, error.message)
  end
end
