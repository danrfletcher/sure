# frozen_string_literal: true

module ReceiptsHelper
  STATUS_TONES = {
    "needs_attention" => :warning,
    "waiting" => :info,
    "matched" => :success,
    "archived" => :neutral,
    "dismissed" => :neutral
  }.freeze

  def receipt_status_pill(receipt)
    render DS::Pill.new(
      label: t("receipts.status.#{receipt.status}"),
      tone: STATUS_TONES.fetch(receipt.status),
      marker: false
    )
  end

  def receipt_total(receipt)
    return t("receipts.index.row.no_total") if receipt.total.blank?

    receipt.currency.present? ? Money.new(receipt.total, receipt.currency).format : number_with_precision(receipt.total, precision: 2)
  end

  def receipt_reason(receipt)
    return if receipt.attention_reason.blank?

    t("receipts.reason.#{receipt.attention_reason}", default: receipt.attention_reason.humanize)
  end

  def receipt_candidate_line(candidate)
    amount = candidate["currency"].present? ? Money.new(candidate["amount"].to_d, candidate["currency"]).format : candidate["amount"]
    [ candidate["name"], candidate["date"], amount ].compact_blank.join(" · ")
  end
end
