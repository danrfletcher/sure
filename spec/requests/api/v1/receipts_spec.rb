# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Receipts', type: :request do
  let(:family) do
    Family.create!(name: 'API Family', currency: 'USD', locale: 'en', date_format: '%m-%d-%Y')
  end
  let(:user) do
    family.users.create!(
      email: 'api-user@example.com',
      password: 'password123',
      password_confirmation: 'password123',
      role: 'admin'
    )
  end
  let(:api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: user,
      name: 'API Docs Key',
      key: key,
      scopes: %w[read_write],
      source: 'web'
    )
  end
  let(:'X-Api-Key') { api_key.plain_key }
  let(:guest) do
    family.users.create!(
      email: 'api-guest@example.com',
      password: 'password123',
      password_confirmation: 'password123',
      role: 'guest'
    )
  end
  let(:guest_api_key) do
    ApiKey.create!(user: guest, name: 'Guest Docs Key', key: ApiKey.generate_secure_key, scopes: %w[read_write], source: 'web')
  end

  def receipt_file(content: "%PDF-1.4 docs receipt #{SecureRandom.hex(4)}", filename: 'receipt.pdf')
    Rack::Test::UploadedFile.new(StringIO.new(content), 'application/pdf', true, original_filename: filename)
  end

  let!(:receipt) do
    Receipt.intake!(
      family: family,
      content: '%PDF-1.4 existing receipt',
      filename: 'existing.pdf',
      content_type: 'application/pdf',
      source: :photo,
      merchant: 'Pret',
      total: 4.5,
      currency: 'GBP'
    ).first
  end

  path '/api/v1/receipts' do
    get 'List queued receipts' do
      description 'Lists the family\'s receipts, newest first. Requires an admin or member.'
      tags 'Receipts'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      parameter name: :status, in: :query, required: false,
                schema: { type: :string, enum: %w[waiting archived needs_attention matched dismissed] }
      parameter name: :source, in: :query, required: false,
                schema: { type: :string, enum: %w[photo email] }
      parameter name: :source_ref, in: :query, type: :string, required: false,
                description: 'Only receipts posted with this source reference'
      parameter name: :content_sha256, in: :query, type: :string, required: false,
                description: 'Find the receipt for a file by its SHA-256 (hex)'
      parameter name: :page, in: :query, type: :integer, required: false, description: 'Page number (default: 1)'
      parameter name: :per_page, in: :query, type: :integer, required: false, description: 'Items per page (default: 25, max: 100)'

      response '200', 'receipts listed' do
        schema '$ref' => '#/components/schemas/ReceiptCollection'
        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:'X-Api-Key') { nil }
        run_test!
      end

      response '403', 'guests cannot use receipts' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:'X-Api-Key') { guest_api_key.plain_key }
        run_test!
      end

      response '422', 'invalid filter' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:status) { 'lost' }
        run_test!
      end
    end

    post 'Queue a receipt' do
      description 'Parks a receipt (PDF or image, max 10 MB) in the queue until its transaction arrives; a nightly job then matches it. ' \
                  'Each file is stored once per family: posting the same file again returns the existing receipt with meta.duplicate = true.'
      tags 'Receipts'
      security [ { apiKeyAuth: [] } ]
      consumes 'multipart/form-data'
      produces 'application/json'

      parameter name: :file, in: :formData, required: true,
                description: 'Receipt file (PDF, JPEG, PNG, GIF or WebP)',
                schema: {
                  type: :object,
                  required: %w[file source],
                  properties: {
                    file: { type: :string, format: :binary },
                    source: { type: :string, enum: %w[photo email], description: 'How the receipt was found' },
                    source_ref: { type: :string, description: 'Reference in the sending system, e.g. an Immich asset id' },
                    merchant: { type: :string },
                    total: { type: :string, description: 'Receipt total as a decimal number' },
                    currency: { type: :string, description: 'ISO 4217 currency code' },
                    receipt_date: { type: :string, format: :date },
                    klarna: { type: :boolean, description: 'The receipt shows Klarna (its transaction can take up to 45 days)' }
                  }
                }
      parameter name: :source, in: :formData, required: true, schema: { type: :string, enum: %w[photo email] }
      parameter name: :merchant, in: :formData, required: false, schema: { type: :string }
      parameter name: :total, in: :formData, required: false, schema: { type: :string }
      parameter name: :currency, in: :formData, required: false, schema: { type: :string }
      parameter name: :receipt_date, in: :formData, required: false, schema: { type: :string, format: :date }

      response '201', 'receipt queued' do
        schema '$ref' => '#/components/schemas/ReceiptResponse'
        let(:file) { receipt_file }
        let(:source) { 'photo' }
        run_test!
      end

      response '200', 'file already queued' do
        schema '$ref' => '#/components/schemas/ReceiptResponse'
        let(:file) { receipt_file(content: '%PDF-1.4 existing receipt') }
        let(:source) { 'photo' }
        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:'X-Api-Key') { nil }
        let(:file) { receipt_file }
        let(:source) { 'photo' }
        run_test!
      end

      response '403', 'guest, or API key without write scope' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:'X-Api-Key') { guest_api_key.plain_key }
        let(:file) { receipt_file }
        let(:source) { 'photo' }
        run_test!
      end

      response '422', 'invalid file or fields' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:file) { receipt_file }
        let(:source) { 'fax' }
        run_test!
      end
    end
  end

  path '/api/v1/receipts/{id}' do
    parameter name: :id, in: :path, type: :string, format: :uuid, required: true

    get 'Show a receipt' do
      description 'Returns one receipt, including the near-miss candidates kept for a receipt that needs attention.'
      tags 'Receipts'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'receipt found' do
        schema '$ref' => '#/components/schemas/ReceiptResponse'
        let(:id) { receipt.id }
        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:'X-Api-Key') { nil }
        let(:id) { receipt.id }
        run_test!
      end

      response '404', 'receipt not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:id) { SecureRandom.uuid }
        run_test!
      end
    end
  end
end
