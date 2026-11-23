# frozen_string_literal: true

require "test_helper"

class Api::V1::ReceiptsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:family_admin)
    @member = users(:family_member)
    @family = @admin.family

    @admin.api_keys.active.destroy_all
    @member.api_keys.active.destroy_all

    @api_key = create_api_key(@admin, "read_write")
    @read_only_api_key = create_api_key(@admin, "read")
  end

  teardown do
    redis = Redis.new
    [ @api_key, @read_only_api_key, @guest_api_key ].compact.each do |key|
      redis.del("api_rate_limit:#{key.id}")
    end
    redis.close
  end

  test "requires authentication" do
    get api_v1_receipts_url
    assert_response :unauthorized

    post api_v1_receipts_url, params: { file: receipt_upload, source: "photo" }
    assert_response :unauthorized
  end

  test "stores a receipt with its fields" do
    assert_difference "Receipt.count", 1 do
      post api_v1_receipts_url,
           params: {
             file: receipt_upload, source: "photo", source_ref: "immich-asset-1", merchant: "Pret",
             total: "4.50", currency: "gbp", receipt_date: "2026-11-20", klarna: "true"
           },
           headers: api_headers(@api_key)
    end

    assert_response :created
    body = JSON.parse(response.body)
    receipt = @family.receipts.find(body["data"]["id"])

    assert receipt.file.attached?
    assert_equal false, body["meta"]["duplicate"]
    assert_equal "waiting", body["data"]["status"]
    assert_equal "photo", body["data"]["source"]
    assert_equal "immich-asset-1", body["data"]["source_ref"]
    assert_equal "Pret", body["data"]["merchant"]
    assert_equal "4.5", body["data"]["total"]
    assert_equal "GBP", body["data"]["currency"]
    assert_equal "2026-11-20", body["data"]["receipt_date"]
    assert_equal true, body["data"]["klarna"]
    assert_equal receipt.content_sha256, body["data"]["content_sha256"]
    assert_equal "application/pdf", body["data"]["content_type"]
  end

  test "posting the same file twice gives one record" do
    content = pdf_content

    post api_v1_receipts_url, params: { file: receipt_upload(content: content), source: "photo" }, headers: api_headers(@api_key)
    assert_response :created
    first_id = JSON.parse(response.body)["data"]["id"]

    assert_no_difference [ "Receipt.count", "ActiveStorage::Blob.count" ] do
      post api_v1_receipts_url, params: { file: receipt_upload(content: content), source: "email" }, headers: api_headers(@api_key)
    end

    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal first_id, body["data"]["id"]
    assert_equal true, body["meta"]["duplicate"]
    assert_equal "photo", body["data"]["source"]
  end

  test "accepts an image" do
    post api_v1_receipts_url,
         params: { file: uploaded_file(filename: "r.png", content_type: "image/png", content: png_content), source: "photo" },
         headers: api_headers(@api_key)

    assert_response :created
    assert_equal "image/png", JSON.parse(response.body)["data"]["content_type"]
  end

  test "rejects a missing file" do
    post api_v1_receipts_url, params: { source: "photo" }, headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    assert_equal "validation_failed", JSON.parse(response.body)["error"]
  end

  test "rejects a file that is not a PDF or image whatever it claims" do
    assert_no_difference "Receipt.count" do
      post api_v1_receipts_url,
           params: { file: uploaded_file(filename: "r.pdf", content_type: "application/pdf", content: "just some text"), source: "photo" },
           headers: api_headers(@api_key)
    end

    assert_response :unprocessable_entity
  end

  test "rejects a file over the size limit" do
    big = "%PDF-1.4 " + ("a" * (Receipt::MAX_FILE_SIZE + 1))

    assert_no_difference "Receipt.count" do
      post api_v1_receipts_url, params: { file: receipt_upload(content: big), source: "photo" }, headers: api_headers(@api_key)
    end

    assert_response :unprocessable_entity
  end

  test "rejects an unknown source, a bad total and a bad date" do
    post api_v1_receipts_url, params: { file: receipt_upload, source: "fax" }, headers: api_headers(@api_key)
    assert_response :unprocessable_entity

    post api_v1_receipts_url, params: { file: receipt_upload, source: "photo", total: "lots" }, headers: api_headers(@api_key)
    assert_response :unprocessable_entity

    post api_v1_receipts_url, params: { file: receipt_upload, source: "photo", receipt_date: "20th Nov" }, headers: api_headers(@api_key)
    assert_response :unprocessable_entity

    assert_equal 0, Receipt.count
  end

  test "a read-only key cannot post" do
    assert_no_difference "Receipt.count" do
      post api_v1_receipts_url, params: { file: receipt_upload, source: "photo" }, headers: api_headers(@read_only_api_key)
    end

    assert_response :forbidden
  end

  test "guests are refused" do
    guest = users(:family_member).tap { |u| u.update!(role: "guest") }
    guest.api_keys.active.destroy_all
    @guest_api_key = create_api_key(guest, "read_write")

    get api_v1_receipts_url, headers: api_headers(@guest_api_key)

    assert_response :forbidden
  end

  test "lists receipts for the family, newest first, with filters" do
    older = create_receipt(source: :photo, source_ref: "a", created_at: 2.days.ago)
    newer = create_receipt(source: :email, source_ref: "b")
    newer.flag_for_attention!(reason: "no_transaction_found")
    create_receipt(family: families(:empty))

    get api_v1_receipts_url, headers: api_headers(@read_only_api_key)

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal [ newer.id, older.id ], body["data"].map { |r| r["id"] }
    assert_equal 2, body["meta"]["total_count"]

    get api_v1_receipts_url, params: { status: "needs_attention" }, headers: api_headers(@read_only_api_key)
    assert_equal [ newer.id ], JSON.parse(response.body)["data"].map { |r| r["id"] }

    get api_v1_receipts_url, params: { source: "photo" }, headers: api_headers(@read_only_api_key)
    assert_equal [ older.id ], JSON.parse(response.body)["data"].map { |r| r["id"] }

    get api_v1_receipts_url, params: { source_ref: "b" }, headers: api_headers(@read_only_api_key)
    assert_equal [ newer.id ], JSON.parse(response.body)["data"].map { |r| r["id"] }

    get api_v1_receipts_url, params: { content_sha256: older.content_sha256.upcase }, headers: api_headers(@read_only_api_key)
    assert_equal [ older.id ], JSON.parse(response.body)["data"].map { |r| r["id"] }
  end

  test "paginates" do
    3.times { create_receipt }

    get api_v1_receipts_url, params: { per_page: 2, page: 2 }, headers: api_headers(@read_only_api_key)

    body = JSON.parse(response.body)
    assert_equal 1, body["data"].size
    assert_equal 2, body["meta"]["total_pages"]
  end

  test "rejects an invalid status or source filter" do
    get api_v1_receipts_url, params: { status: "lost" }, headers: api_headers(@read_only_api_key)
    assert_response :unprocessable_entity

    get api_v1_receipts_url, params: { source: "lost" }, headers: api_headers(@read_only_api_key)
    assert_response :unprocessable_entity
  end

  test "shows a receipt with its near-miss candidates" do
    receipt = create_receipt
    receipt.flag_for_attention!(reason: "ambiguous", candidates: [ { "transaction_id" => SecureRandom.uuid, "reason" => "amount" } ])

    get api_v1_receipt_url(receipt), headers: api_headers(@read_only_api_key)

    assert_response :success
    data = JSON.parse(response.body)["data"]
    assert_equal receipt.id, data["id"]
    assert_equal "ambiguous", data["attention_reason"]
    assert_equal 1, data["candidates"].size
  end

  test "show returns 404 for another family's receipt and for a bad id" do
    foreign = create_receipt(family: families(:empty))

    get api_v1_receipt_url(foreign), headers: api_headers(@read_only_api_key)
    assert_response :not_found

    get api_v1_receipt_url("not-a-uuid"), headers: api_headers(@read_only_api_key)
    assert_response :not_found
  end

  private

    def create_api_key(user, scope)
      ApiKey.create!(
        user: user,
        name: "Test #{scope} key",
        scopes: [ scope ],
        display_key: "test_#{scope}_#{SecureRandom.hex(8)}",
        source: scope == "read" ? "mobile" : "web"
      )
    end

    def pdf_content
      "%PDF-1.4 receipt #{SecureRandom.hex(8)}"
    end

    def png_content
      # 1x1 transparent PNG
      Base64.decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")
    end

    def receipt_upload(content: pdf_content, filename: "receipt.pdf")
      uploaded_file(filename: filename, content_type: "application/pdf", content: content)
    end

    def create_receipt(family: @family, **attributes)
      receipt, = Receipt.intake!(
        family: family, content: pdf_content, filename: "r.pdf", content_type: "application/pdf",
        **{ source: :photo }.merge(attributes)
      )
      receipt
    end
end
