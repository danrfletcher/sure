require "test_helper"

class ReceiptTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @content = "%PDF-1.4 fake receipt #{SecureRandom.hex(4)}"
  end

  def intake(content: @content, **attributes)
    Receipt.intake!(
      family: @family,
      content: content,
      filename: "receipt.pdf",
      content_type: "application/pdf",
      **{ source: :photo }.merge(attributes)
    )
  end

  test "intake stores the file and starts the receipt waiting" do
    receipt, created = intake(merchant: "Pret", total: 4.5, currency: "gbp", receipt_date: Date.current - 2, source_ref: "immich-1")

    assert created
    assert receipt.persisted?
    assert receipt.waiting?
    assert receipt.file.attached?
    assert_equal "GBP", receipt.currency
    assert_equal Receipt.sha256_of(@content), receipt.content_sha256
    assert_equal @content.bytesize, receipt.byte_size
    assert_equal @content, receipt.file.download
  end

  test "intake of the same file twice gives one record and one blob" do
    first, = intake
    assert_no_difference [ "Receipt.count", "ActiveStorage::Blob.count" ] do
      second, created = intake(merchant: "Other")
      assert_not created
      assert_equal first, second
    end
  end

  test "the same file can be queued by different families" do
    intake
    other_family = families(:empty)
    receipt, created = Receipt.intake!(family: other_family, content: @content, filename: "r.pdf", content_type: "application/pdf", source: :email)

    assert created
    assert_equal other_family, receipt.family
  end

  test "requires a known source and an allowed content type" do
    assert_raises(ActiveRecord::RecordInvalid) { intake(source: "carrier_pigeon") }

    assert_raises(ActiveRecord::RecordInvalid) do
      Receipt.intake!(family: @family, content: "MZ", filename: "r.exe", content_type: "application/x-msdownload", source: :photo)
    end
  end

  test "rejects files over the size limit" do
    receipt = @family.receipts.build(source: :photo, filename: "r.pdf", content_type: "application/pdf",
                                     byte_size: Receipt::MAX_FILE_SIZE + 1, content_sha256: Receipt.sha256_of("x"))
    receipt.file.attach(io: StringIO.new("x"), filename: "r.pdf", content_type: "application/pdf")

    assert_not receipt.valid?
    assert receipt.errors[:byte_size].any?
  end

  test "needs_attention requires a reason" do
    receipt, = intake

    assert_raises(ActiveRecord::RecordInvalid) { receipt.update!(status: :needs_attention) }

    receipt.flag_for_attention!(reason: "no_transaction_found", candidates: [ { "transaction_id" => "abc" } ])
    assert receipt.needs_attention?
    assert_equal "no_transaction_found", receipt.attention_reason
    assert_equal [ { "transaction_id" => "abc" } ], receipt.candidates
  end

  test "mark_matched links a transaction of the same family and clears attention state" do
    receipt, = intake
    receipt.flag_for_attention!(reason: "ambiguous")
    transaction = @family.transactions.first

    receipt.mark_matched!(transaction)

    assert receipt.matched?
    assert_equal transaction, receipt.matched_transaction
    assert_not_nil receipt.matched_at
    assert_nil receipt.attention_reason
    assert_empty receipt.candidates
  end

  test "cannot be matched to another family's transaction" do
    receipt, = intake
    other_account = Account.create!(family: families(:empty), name: "Other", balance: 0, currency: "USD", accountable: Depository.new)
    foreign = create_transaction(account: other_account).entryable

    assert_raises(ActiveRecord::RecordInvalid) { receipt.mark_matched!(foreign) }
  end

  test "matched requires a transaction" do
    receipt, = intake

    assert_raises(ActiveRecord::RecordInvalid) { receipt.update!(status: :matched) }
  end

  test "archive, dismiss and requeue move the status" do
    receipt, = intake

    receipt.archive!(reason: "older_than_wait_window")
    assert receipt.archived?
    assert_equal "older_than_wait_window", receipt.attention_reason

    receipt.requeue!
    assert receipt.waiting?
    assert_nil receipt.attention_reason

    receipt.dismiss!
    assert receipt.dismissed?
  end

  test "in_queue only holds waiting receipts" do
    waiting, = intake
    done, = intake(content: "%PDF-1.4 other #{SecureRandom.hex(4)}")
    done.dismiss!

    assert_includes Receipt.in_queue, waiting
    assert_not_includes Receipt.in_queue, done
  end

  test "deleting the matched transaction keeps the receipt and clears the link" do
    receipt, = intake
    transaction = @family.transactions.first
    receipt.mark_matched!(transaction)

    transaction.entry.destroy!

    assert Receipt.exists?(receipt.id)
    assert_nil receipt.reload.matched_transaction_id
  end

  test "destroying a receipt removes it" do
    receipt, = intake
    assert_difference "Receipt.count", -1 do
      receipt.destroy!
    end
  end

  test "attach_to! reuses the blob and marks the receipt matched" do
    receipt, = intake
    transaction = @family.transactions.first

    assert_no_difference "ActiveStorage::Blob.count" do
      assert_equal :matched, receipt.attach_to!(transaction)
    end

    assert receipt.reload.matched?
    assert_equal receipt.file.blob.id, transaction.attachments.last.blob.id
  end

  test "attach_to! stops at the attachment limit without changing the receipt" do
    receipt, = intake
    transaction = @family.transactions.first
    transaction.stubs(:attachments).returns(stub(size: Transaction::MAX_ATTACHMENTS_PER_TRANSACTION))

    assert_equal :attachment_limit, receipt.attach_to!(transaction)
    assert receipt.reload.waiting?
  end

  test "open? is true until a receipt is matched or dismissed" do
    receipt, = intake
    assert receipt.open?

    receipt.flag_for_attention!(reason: "ambiguous")
    assert receipt.open?

    receipt.dismiss!
    assert_not receipt.open?
  end
end
