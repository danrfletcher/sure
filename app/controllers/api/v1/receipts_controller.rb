# frozen_string_literal: true

class Api::V1::ReceiptsController < Api::V1::BaseController
  include Pagy::Backend

  before_action :ensure_read_scope, only: [ :index, :show ]
  before_action :ensure_write_scope, only: [ :create ]
  before_action :ensure_receipt_manager
  before_action :set_receipt, only: [ :show ]

  def index
    receipts = apply_filters(family.receipts.ordered)
    @per_page = safe_per_page_param
    @pagy, @receipts = pagy(receipts, page: safe_page_param, limit: @per_page)

    render :index
  end

  def show
    render :show
  end

  def create
    file = params[:file]
    unless file.respond_to?(:read) && file.respond_to?(:original_filename)
      render_validation_error("file is required (multipart/form-data)")
      return
    end

    upload = Receipt.read_upload!(file)
    @receipt, created = Receipt.intake!(family: family, **upload, **receipt_attributes)
    @duplicate = !created

    render :show, status: created ? :created : :ok
  rescue Receipt::InvalidUploadError => e
    render_validation_error(e.message)
  rescue ActiveRecord::RecordInvalid => e
    render json: {
      error: "validation_failed",
      message: "Receipt could not be stored",
      errors: e.record.errors.full_messages
    }, status: :unprocessable_entity
  end

  private

    def family
      current_resource_owner.family
    end

    def set_receipt
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])

      @receipt = family.receipts.find(params[:id])
    end

    def receipt_attributes
      attributes = {
        source: params[:source].to_s,
        source_ref: params[:source_ref].presence,
        merchant: params[:merchant].presence,
        total: params[:total].presence,
        currency: params[:currency].presence,
        klarna: ActiveModel::Type::Boolean.new.cast(params[:klarna]) || false
      }

      if params[:receipt_date].present?
        date = parse_date(params[:receipt_date].to_s)
        raise InvalidFilterError, "receipt_date must be an ISO 8601 date" unless date

        attributes[:receipt_date] = date
      end

      attributes
    end

    def apply_filters(scope)
      if params[:status].present?
        unless Receipt.statuses.key?(params[:status].to_s)
          raise InvalidFilterError, "status must be one of: #{Receipt.statuses.keys.join(", ")}"
        end

        scope = scope.where(status: params[:status].to_s)
      end

      if params[:source].present?
        unless Receipt.sources.key?(params[:source].to_s)
          raise InvalidFilterError, "source must be one of: #{Receipt.sources.keys.join(", ")}"
        end

        scope = scope.where(source: params[:source].to_s)
      end

      scope = scope.where(source_ref: params[:source_ref].to_s) if params[:source_ref].present?
      scope = scope.where(content_sha256: params[:content_sha256].to_s.strip.downcase) if params[:content_sha256].present?
      scope
    end

    def ensure_receipt_manager
      return if Receipt.manager?(current_resource_owner)

      render json: {
        error: "forbidden",
        message: "Receipts require an admin or member role"
      }, status: :forbidden
    end

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def ensure_write_scope
      authorize_scope!(:write)
    end
end
