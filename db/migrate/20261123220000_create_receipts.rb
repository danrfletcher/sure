# frozen_string_literal: true

class CreateReceipts < ActiveRecord::Migration[7.2]
  def change
    create_table :receipts, id: :uuid do |t|
      t.references :family, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.references :matched_transaction, null: true, type: :uuid, foreign_key: { to_table: :transactions, on_delete: :nullify }

      t.string :status, null: false, default: "waiting"
      t.string :source, null: false
      t.string :source_ref, limit: 255

      t.string :merchant, limit: 255
      t.decimal :total, precision: 19, scale: 4
      t.string :currency, limit: 3
      t.date :receipt_date
      t.boolean :klarna, null: false, default: false

      t.string :filename, null: false, limit: 255
      t.string :content_type, null: false, limit: 100
      t.bigint :byte_size, null: false
      t.string :content_sha256, null: false, limit: 64

      t.string :attention_reason
      t.jsonb :candidates, null: false, default: []
      t.datetime :matched_at

      t.timestamps

      t.index [ :family_id, :content_sha256 ], unique: true, name: "index_receipts_on_family_and_content_sha256"
      t.index [ :family_id, :status ], name: "index_receipts_on_family_and_status"
    end
  end
end
