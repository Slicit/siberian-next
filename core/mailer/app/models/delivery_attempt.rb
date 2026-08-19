# frozen_string_literal: true

# One try at delivering one message.
#
# Kept per attempt rather than summarised on the message, because the useful
# question is "why did this take four hours", and a counter cannot answer it.
class DeliveryAttempt < ApplicationRecord
  OUTCOMES = %w[delivered rejected error].freeze

  belongs_to :message

  validates :number, :outcome, :attempted_at, presence: true
  validates :outcome, inclusion: { in: OUTCOMES }

  scope :ordered, -> { order(:number) }

  def delivered? = outcome == "delivered"

  # A rejection is the transport saying no: a bad address, a refused sender.
  # Retrying will produce the same answer, so it does not get one.
  def permanent? = outcome == "rejected"
end
