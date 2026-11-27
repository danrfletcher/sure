namespace :receipts do
  desc "Put archived receipts back in the queue, e.g. after importing older bank history (optionally for one family)"
  task :requeue_archived, [ :family_id ] => :environment do |_t, args|
    scope = Receipt.archived
    scope = scope.where(family_id: args[:family_id]) if args[:family_id].present?

    count = 0
    scope.find_each do |receipt|
      receipt.requeue!
      count += 1
    end

    puts "Re-queued #{count} archived receipt(s). The nightly match picks them up; run ReceiptMatchJob.perform_now to match now."
  end
end
