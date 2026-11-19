require "test_helper"

class Family::AutoConfirmTransfersTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @from = accounts(:depository)
    @to = accounts(:credit_card)
    @on = { "AUTO_CONFIRM_TRANSFERS" => "true", "AUTO_CONFIRM_TRANSFER_NAMES" => "own pot" }
  end

  def pair(out_name:, in_name:, days_apart: 0, amount: 500)
    out = create_transaction(date: Date.current - days_apart, account: @from, amount: amount, name: out_name)
    inn = create_transaction(date: Date.current, account: @to, amount: -amount, name: in_name)
    [ out, inn ]
  end

  test "confirms a pair when both legs carry the family's own names" do
    out, inn = pair(out_name: "OWN POT top-up", in_name: "own pot")

    with_env_overrides(@on) { @family.auto_match_transfers! }

    assert Transfer.find_by!(inflow_transaction_id: inn.entryable_id).confirmed?
    assert_equal "funds_movement", inn.reload.entryable.kind
    assert_not_equal "standard", out.reload.entryable.kind
  end

  test "matches a member's full name without extra configuration" do
    user = @family.users.first
    full = [ user.first_name, user.last_name ].join(" ")
    out, inn = pair(out_name: full.upcase, in_name: "Transfer from #{full}")

    with_env_overrides("AUTO_CONFIRM_TRANSFERS" => "true") { @family.auto_match_transfers! }

    assert Transfer.find_by!(inflow_transaction_id: inn.entryable_id).confirmed?
  end

  test "leaves a pair pending when one leg is a third-party name" do
    _out, inn = pair(out_name: "Corner Shop", in_name: "own pot")

    with_env_overrides(@on) { @family.auto_match_transfers! }

    assert Transfer.find_by!(inflow_transaction_id: inn.entryable_id).pending?
    assert_equal "standard", inn.reload.entryable.kind
  end

  test "leaves a pair pending when the legs are further apart than the window" do
    _out, inn = pair(out_name: "own pot", in_name: "own pot", days_apart: 3)

    with_env_overrides(@on) { @family.auto_match_transfers! }

    assert Transfer.find_by!(inflow_transaction_id: inn.entryable_id).pending?
  end

  test "does nothing unless switched on" do
    _out, inn = pair(out_name: "own pot", in_name: "own pot")

    with_env_overrides("AUTO_CONFIRM_TRANSFERS" => nil, "AUTO_CONFIRM_TRANSFER_NAMES" => "own pot") { @family.auto_match_transfers! }

    assert Transfer.find_by!(inflow_transaction_id: inn.entryable_id).pending?
  end

  test "confirms matches that were already pending when the switch is turned on" do
    _out, inn = pair(out_name: "own pot", in_name: "own pot")
    @family.auto_match_transfers!
    assert Transfer.find_by!(inflow_transaction_id: inn.entryable_id).pending?

    with_env_overrides(@on) { @family.auto_match_transfers! }

    assert Transfer.find_by!(inflow_transaction_id: inn.entryable_id).confirmed?
  end
end
