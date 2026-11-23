# frozen_string_literal: true

json.id receipt.id
json.status receipt.status
json.source receipt.source
json.source_ref receipt.source_ref
json.merchant receipt.merchant
json.total receipt.total&.to_s
json.currency receipt.currency
json.receipt_date receipt.receipt_date&.iso8601
json.klarna receipt.klarna
json.filename receipt.filename
json.content_type receipt.content_type
json.byte_size receipt.byte_size
json.content_sha256 receipt.content_sha256
json.attention_reason receipt.attention_reason
json.candidates receipt.candidates
json.matched_transaction_id receipt.matched_transaction_id
json.matched_at receipt.matched_at&.iso8601
json.created_at receipt.created_at.iso8601
json.updated_at receipt.updated_at.iso8601
