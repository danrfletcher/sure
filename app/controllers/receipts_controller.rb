# frozen_string_literal: true

# Receipts waiting for a transaction. The list is of receipts, not of
# transactions that lack one.
class ReceiptsController < ApplicationController
  include SafePagination

  STATUS_TABS = %w[needs_attention waiting matched archived dismissed].freeze

  before_action :ensure_receipt_manager!
  before_action :set_receipt, only: :file

  def index
    @status = STATUS_TABS.include?(params[:status]) ? params[:status] : "needs_attention"
    @counts = Current.family.receipts.group(:status).count
    @pagy, @receipts = pagy(
      Current.family.receipts.where(status: @status).with_attached_file.includes(:matched_transaction).ordered,
      limit: safe_per_page(25)
    )
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("receipts.index.title"), nil ]
    ]
  end

  def file
    redirect_to rails_blob_path(@receipt.file, disposition: "inline", only_path: true)
  end

  private

    def ensure_receipt_manager!
      return if Receipt.manager?(Current.user)

      redirect_to root_path, alert: t("receipts.not_authorized")
    end

    def set_receipt
      @receipt = Current.family.receipts.find(params[:id])
    end
end
