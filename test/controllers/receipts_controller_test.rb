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

  # --- manual matching ---

  def spend(amount:, name:, days_ago: 1, account: accounts(:depository))
    create_transaction(account: account, name: name, amount: amount, date: Date.current - days_ago)
  end

  test "show starts from the receipt's merchant and dates and lists matching transactions" do
    receipt = create_receipt(merchant: "Gadget Store", total: 55.55)
    receipt.flag_for_attention!(reason: "no_transaction_found")
    near = spend(amount: 60, name: "GADGET STORE LONDON")
    spend(amount: 60, name: "SOMETHING ELSE")

    get receipt_url(receipt)

    assert_response :success
    assert_select "input[name='q[search]'][value=?]", "Gadget Store"
    assert_select "##{ActionView::RecordIdentifier.dom_id(near.entryable, :candidate)}", count: 1
    assert_select "td", text: "SOMETHING ELSE", count: 0
  end

  test "show searches by amount, name and date" do
    receipt = create_receipt(merchant: "Gadget Store")
    by_amount = spend(amount: 123.45, name: "ODD NAME", days_ago: 3)
    spend(amount: 99.0, name: "ODD NAME TWO", days_ago: 3)
    old = spend(amount: 123.45, name: "OLD ONE", days_ago: 60)

    get receipt_url(receipt, q: { search: "", amount: "123.45", start_date: (Date.current - 90).iso8601, end_date: Date.current.iso8601 })

    assert_response :success
    assert_select "##{ActionView::RecordIdentifier.dom_id(by_amount.entryable, :candidate)}", count: 1
    assert_select "##{ActionView::RecordIdentifier.dom_id(old.entryable, :candidate)}", count: 1
    assert_select "td", text: "ODD NAME TWO", count: 0
  end

  test "transactions that already hold a receipt are not offered" do
    taken = spend(amount: 10, name: "TAKEN SHOP")
    create_receipt.mark_matched!(taken.entryable)
    receipt = create_receipt(merchant: "Taken Shop")

    get receipt_url(receipt)

    assert_select "td", text: "TAKEN SHOP", count: 0
  end

  test "matching attaches the receipt's blob to the transaction" do
    receipt = create_receipt(merchant: "Gadget Store")
    receipt.flag_for_attention!(reason: "no_transaction_found")
    entry = spend(amount: 60, name: "GADGET STORE LONDON")

    assert_no_difference "ActiveStorage::Blob.count" do
      patch match_receipt_url(receipt), params: { transaction_id: entry.entryable.id }
    end

    assert_redirected_to receipts_path
    assert receipt.reload.matched?
    assert_equal entry.entryable, receipt.matched_transaction
    assert_equal [ receipt.file.blob.id ], entry.entryable.attachments.map { |a| a.blob.id }
  end

  test "an archived receipt can be matched by hand" do
    receipt = create_receipt(receipt_date: Date.current - 200)
    assert receipt.archived?
    entry = spend(amount: 5, name: "OLD SHOP", days_ago: 199)

    patch match_receipt_url(receipt), params: { transaction_id: entry.entryable.id }

    assert receipt.reload.matched?
  end

  test "matching refuses another family's transaction" do
    receipt = create_receipt
    foreign_account = Account.create!(family: families(:empty), name: "Theirs", balance: 0, currency: "USD", accountable: Depository.new)
    foreign = spend(amount: 5, name: "THEIRS", account: foreign_account)

    patch match_receipt_url(receipt), params: { transaction_id: foreign.entryable.id }

    assert_redirected_to receipt_path(receipt)
    assert receipt.reload.waiting?
    assert_not foreign.entryable.attachments.attached?
  end

  test "matching refuses a transaction that already holds a receipt" do
    entry = spend(amount: 5, name: "TAKEN")
    create_receipt.mark_matched!(entry.entryable)
    receipt = create_receipt

    patch match_receipt_url(receipt), params: { transaction_id: entry.entryable.id }

    assert_redirected_to receipt_path(receipt)
    assert receipt.reload.waiting?
  end

  test "matching a transaction at its attachment limit leaves the receipt as it was" do
    receipt = create_receipt
    entry = spend(amount: 5, name: "FULL")
    Transaction.any_instance.stubs(:attachments).returns(stub(size: Transaction::MAX_ATTACHMENTS_PER_TRANSACTION))

    patch match_receipt_url(receipt), params: { transaction_id: entry.entryable.id }

    assert_redirected_to receipt_path(receipt)
    assert_equal I18n.t("receipts.match.attachment_limit", max: Transaction::MAX_ATTACHMENTS_PER_TRANSACTION), flash[:alert]
    assert receipt.reload.waiting?
  end

  test "a matched receipt can't be matched again or dismissed" do
    entry = spend(amount: 5, name: "DONE")
    receipt = create_receipt
    receipt.mark_matched!(entry.entryable)
    other = spend(amount: 5, name: "OTHER")

    patch match_receipt_url(receipt), params: { transaction_id: other.entryable.id }
    assert_redirected_to receipt_path(receipt)
    assert_equal entry.entryable, receipt.reload.matched_transaction

    patch dismiss_receipt_url(receipt)
    assert receipt.reload.matched?
  end

  test "dismissing marks a receipt as not a receipt" do
    receipt = create_receipt
    receipt.flag_for_attention!(reason: "ambiguous")

    patch dismiss_receipt_url(receipt)

    assert_redirected_to receipts_path
    assert receipt.reload.dismissed?
  end

  test "an archived receipt can be put back in the queue" do
    receipt = create_receipt(receipt_date: Date.current - 200)
    assert receipt.archived?

    patch requeue_receipt_url(receipt)

    assert_redirected_to receipts_path(status: "waiting")
    assert receipt.reload.waiting?
  end

  test "only archived receipts can be requeued" do
    receipt = create_receipt
    receipt.flag_for_attention!(reason: "ambiguous")

    patch requeue_receipt_url(receipt)

    assert_redirected_to receipt_path(receipt)
    assert receipt.reload.needs_attention?
  end

  test "another family's receipt can't be shown, matched, dismissed or requeued" do
    foreign = create_receipt(family: families(:empty))
    entry = spend(amount: 5, name: "MINE")

    get receipt_url(foreign)
    assert_response :not_found

    patch match_receipt_url(foreign), params: { transaction_id: entry.entryable.id }
    assert_response :not_found

    patch dismiss_receipt_url(foreign)
    assert_response :not_found

    patch requeue_receipt_url(foreign)
    assert_response :not_found

    assert foreign.reload.waiting?
  end

  test "guests can't match or dismiss" do
    receipt = create_receipt
    guest = users(:family_member)
    guest.update!(role: "guest")
    sign_in guest

    patch dismiss_receipt_url(receipt)

    assert_redirected_to root_path
    assert receipt.reload.waiting?
  end

  test "a member with read-only access to an account can't match to its transactions" do
    entry = spend(amount: 5, name: "ADMINS ACCOUNT", account: accounts(:credit_card))
    receipt = create_receipt(merchant: "Admins Account")
    sign_in users(:family_member)

    get receipt_url(receipt)
    assert_select "td", text: "ADMINS ACCOUNT", count: 0

    patch match_receipt_url(receipt), params: { transaction_id: entry.entryable.id }
    assert_redirected_to receipt_path(receipt)
    assert receipt.reload.waiting?
  end
end
