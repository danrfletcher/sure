require "test_helper"

class ReceiptsControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    ensure_tailwind_build
    sign_in @user = users(:family_admin)
    @family = @user.family
  end

  def create_receipt(family: @family, **attributes)
    receipt, = Receipt.intake!(
      family: family, content: "%PDF-1.4 #{SecureRandom.hex(8)}", filename: "r.pdf", content_type: "application/pdf",
      **{ source: :photo, receipt_date: Date.current - 1 }.merge(attributes)
    )
    receipt
  end

  test "lists receipts that need attention first, with their reason and near misses" do
    needs = create_receipt(merchant: "Gadget Store", total: 55.55, currency: "USD")
    needs.flag_for_attention!(reason: "no_transaction_found", candidates: [
      { "transaction_id" => SecureRandom.uuid, "name" => "GADGET STORE LONDON", "date" => "2026-11-20", "amount" => "50.01", "currency" => "USD" }
    ])
    waiting = create_receipt(merchant: "Waiting Shop")

    get receipts_url

    assert_response :success
    assert_select "h1", text: I18n.t("receipts.index.title")
    assert_select "##{ActionView::RecordIdentifier.dom_id(needs)}", count: 1
    assert_select "##{ActionView::RecordIdentifier.dom_id(waiting)}", count: 0
    assert_select "td", text: /No transaction found/
    assert_select "li", text: /GADGET STORE LONDON/
  end

  test "filter tabs show each status with counts" do
    create_receipt.flag_for_attention!(reason: "ambiguous")
    waiting = create_receipt(merchant: "Waiting Shop")
    create_receipt.dismiss!

    get receipts_url(status: "waiting")

    assert_response :success
    assert_select "##{ActionView::RecordIdentifier.dom_id(waiting)}", count: 1
    assert_select "[data-testid=receipts-tab-needs_attention]", text: "Needs attention (1)"
    assert_select "[data-testid=receipts-tab-waiting][aria-current=true]"
    assert_select "[data-testid=receipts-tab-dismissed]", text: "Dismissed (1)"
  end

  test "an unknown status falls back to needs attention" do
    needs = create_receipt
    needs.flag_for_attention!(reason: "ambiguous")

    get receipts_url(status: "bogus")

    assert_response :success
    assert_select "##{ActionView::RecordIdentifier.dom_id(needs)}", count: 1
  end

  test "a receipt without a total or date still renders" do
    receipt = create_receipt(total: nil, receipt_date: nil)
    receipt.flag_for_attention!(reason: "missing_details")

    get receipts_url

    assert_response :success
    assert_select "td", text: I18n.t("receipts.index.row.no_total")
    assert_select "td", text: I18n.t("receipts.index.row.no_date")
  end

  test "shows an empty state" do
    get receipts_url

    assert_response :success
    assert_select "p", text: I18n.t("receipts.index.empty.needs_attention.title")
  end

  test "matched receipts link to their transaction" do
    entry = create_transaction(account: accounts(:depository), name: "Matched Shop", amount: 12.5, date: Date.current)
    receipt = create_receipt
    receipt.mark_matched!(entry.entryable)

    get receipts_url(status: "matched")

    assert_response :success
    assert_select "a[href=?]", entry_path(entry), text: "Matched Shop"
  end

  test "only shows the family's own receipts" do
    foreign = create_receipt(family: families(:empty), merchant: "Foreign")
    foreign.flag_for_attention!(reason: "ambiguous")

    get receipts_url

    assert_select "##{ActionView::RecordIdentifier.dom_id(foreign)}", count: 0
  end

  test "the nav shows a count badge for receipts that need attention" do
    2.times { create_receipt.flag_for_attention!(reason: "ambiguous") }
    create_receipt # waiting receipts are not counted

    get root_url

    assert_response :success
    assert_select "a[href=?]", receipts_path do
      assert_select "span", text: "2"
    end
  end

  test "the nav has no badge when nothing needs attention" do
    create_receipt

    get root_url

    assert_select "a[href=?]", receipts_path
    assert_select "a[href=?] span", receipts_path, text: /\A\d+\z/, count: 0
  end

  test "serves the receipt file" do
    receipt = create_receipt

    get file_receipt_url(receipt)

    assert_response :redirect
    follow_redirect!
    assert_response :redirect # blob redirect to the storage service
  end

  test "another family's receipt file is not found" do
    foreign = create_receipt(family: families(:empty))

    get file_receipt_url(foreign)

    assert_response :not_found
  end

  test "guests are turned away and see no nav entry" do
    guest = users(:family_member)
    guest.update!(role: "guest")
    sign_in guest

    get receipts_url

    assert_redirected_to root_path
  end
end
