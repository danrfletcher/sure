require "test_helper"

class GocardlessItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @item = @user.family.gocardless_items.create!(
      name: "Revolut", secret_id: "id", secret_key: "key", requisition_id: "req-1", institution_id: "REVOLUT_REVOGB21"
    )
    @current = @item.gocardless_accounts.create!(
      gocardless_account_id: "a1", name: "Joint", currency: "GBP", current_balance: 288.10, account_type: "CACC"
    )
    @saver = @item.gocardless_accounts.create!(
      gocardless_account_id: "a2", name: "Pot", currency: "GBP", current_balance: 1, account_type: "SVGS"
    )
    GocardlessItem.any_instance.stubs(:sync_later)
  end

  test "ticking accounts on the setup screen creates and links Sure accounts" do
    assert_difference -> { @user.family.accounts.count }, 2 do
      post complete_account_setup_gocardless_item_url(@item), params: { selected_accounts: [ @current.id, @saver.id ] }
    end

    assert_redirected_to accounts_path
    joint = @current.reload.current_account
    assert_equal "Joint", joint.name
    assert_equal "checking", joint.accountable.subtype
    assert_equal "savings", @saver.reload.current_account.accountable.subtype
  end

  test "submitting with nothing ticked creates nothing" do
    assert_no_difference -> { Account.count } do
      post complete_account_setup_gocardless_item_url(@item)
    end
    assert_redirected_to setup_accounts_gocardless_item_path(@item)
  end

  test "dashboard warns when a bank consent is about to lapse" do
    @item.update!(consent_expires_at: 3.days.from_now)

    get root_path
    assert_includes response.body, "Revolut access expires in"
    assert_select "form[action=?]", reconnect_gocardless_item_path(@item)
  end

  test "no warning while a consent has plenty of time left" do
    @item.update!(consent_expires_at: 60.days.from_now)

    get root_path
    assert_not_includes response.body, "Re-link it to keep syncing"
  end

  test "an expired consent says syncing has stopped" do
    @item.update!(status: :requires_update, consent_expires_at: 1.day.ago)

    get root_path
    assert_includes response.body, "has expired, so it has stopped syncing"
  end
end
