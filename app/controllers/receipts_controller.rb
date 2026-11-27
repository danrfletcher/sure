# frozen_string_literal: true

# Receipts waiting for a transaction. The list is of receipts, not of
# transactions that lack one.
class ReceiptsController < ApplicationController
  include SafePagination

  STATUS_TABS = %w[needs_attention waiting matched archived dismissed].freeze

  before_action :ensure_receipt_manager!
  before_action :set_receipt, only: %i[show file match dismiss requeue]
  before_action :ensure_open_receipt!, only: %i[match dismiss]

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

  def show
    @finder = Receipt::TransactionFinder.new(@receipt, user: Current.user, params: search_params)
    @transactions = @receipt.open? ? @finder.transactions : Transaction.none
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("receipts.index.title"), receipts_path ],
      [ @receipt.merchant.presence || @receipt.filename, nil ]
    ]
  end

  def file
    redirect_to rails_blob_path(@receipt.file, disposition: "inline", only_path: true)
  end

  def match
    transaction = Current.family.transactions.find_by(id: params[:transaction_id])
    finder = Receipt::TransactionFinder.new(@receipt, user: Current.user)

    unless transaction && finder.pickable?(transaction)
      redirect_to receipt_path(@receipt), alert: t("receipts.match.not_available")
      return
    end

    case @receipt.attach_to!(transaction)
    when :matched
      redirect_to receipts_path, notice: t("receipts.match.matched", transaction: transaction.entry.name)
    when :attachment_limit
      redirect_to receipt_path(@receipt), alert: t("receipts.match.attachment_limit", max: Transaction::MAX_ATTACHMENTS_PER_TRANSACTION)
    else
      redirect_to receipt_path(@receipt), alert: t("receipts.match.failed")
    end
  end

  def dismiss
    @receipt.dismiss!
    redirect_to receipts_path, notice: t("receipts.dismiss.dismissed")
  end

  def requeue
    unless @receipt.archived?
      redirect_to receipt_path(@receipt), alert: t("receipts.requeue.not_archived")
      return
    end

    @receipt.requeue!
    redirect_to receipts_path(status: "waiting"), notice: t("receipts.requeue.requeued")
  end

  private

    def ensure_receipt_manager!
      return if Receipt.manager?(Current.user)

      redirect_to root_path, alert: t("receipts.not_authorized")
    end

    def set_receipt
      @receipt = Current.family.receipts.find(params[:id])
    end

    def ensure_open_receipt!
      return if @receipt.open?

      redirect_to receipt_path(@receipt), alert: t("receipts.not_open")
    end

    # nil on first load, so the form starts from the receipt's own details
    def search_params
      params[:q].respond_to?(:permit) ? params[:q].permit(:search, :amount, :start_date, :end_date) : nil
    end
end
