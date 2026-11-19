class GocardlessItem::SyncCompleteEvent
  attr_reader :gocardless_item

  def initialize(gocardless_item)
    @gocardless_item = gocardless_item
  end

  def broadcast
    # Update UI with latest account data
    gocardless_item.accounts.each do |account|
      account.broadcast_sync_complete
    end

    # Let family handle sync notifications
    gocardless_item.family.broadcast_sync_complete
  end
end
