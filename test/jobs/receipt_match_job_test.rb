require "test_helper"

class ReceiptMatchJobTest < ActiveJob::TestCase
  include EntriesTestHelper

  test "matches waiting receipts for every family that has some" do
    family = families(:dylan_family)
    receipt, = Receipt.intake!(
      family: family, content: "%PDF-1.4 job", filename: "r.pdf", content_type: "application/pdf",
      source: :email, merchant: "Shop", total: 64.46, currency: "USD", receipt_date: Date.current - 2
    )
    entry = create_transaction(account: accounts(:depository), name: "SHOP", amount: 64.46, date: Date.current - 1)

    ReceiptMatchJob.perform_now

    assert_equal entry.entryable, receipt.reload.matched_transaction
  end

  test "one family failing does not stop the others" do
    family = families(:dylan_family)
    Receipt.intake!(family: family, content: "%PDF-1.4 job2", filename: "r.pdf", content_type: "application/pdf", source: :email, total: 1, receipt_date: Date.current)
    Receipt::Matcher.any_instance.stubs(:run).raises("boom")

    assert_nothing_raised { ReceiptMatchJob.perform_now }
  end

  test "is scheduled nightly on the scheduled queue" do
    entry = YAML.load_file(Rails.root.join("config/schedule.yml")).fetch("match_receipts")

    assert_equal "ReceiptMatchJob", entry["class"]
    assert_equal "scheduled", entry["queue"]
    assert_equal true, entry["active_job"]
    assert_equal "30 3 * * *", entry["cron"]
    assert_equal ReceiptMatchJob, entry["class"].constantize
  end
end
