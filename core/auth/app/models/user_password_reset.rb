# frozen_string_literal: true

# One way back into one core account. See `ResetToken` for the rules.
class UserPasswordReset < ApplicationRecord
  include ResetToken

  belongs_to :user

  def self.owner_key = :user
end
