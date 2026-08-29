# frozen_string_literal: true

# One way back into one app account. See `ResetToken` for the rules.
class AppPasswordReset < ApplicationRecord
  include ResetToken

  belongs_to :app_user

  def self.owner_key = :app_user

  # Kept, because the app's endpoints and the copy in its emails refer to it.
  LIFETIME = ResetToken::LIFETIME
end
