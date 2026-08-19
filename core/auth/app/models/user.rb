# frozen_string_literal: true

# A person. One account across the whole system: the Backoffice, the Base App,
# and every module see the same user, which is the point of shipping auth in
# the core rather than letting every module invent it.
class User < ApplicationRecord
  has_secure_password

  has_many :sessions, dependent: :destroy

  validates :email, presence: true, uniqueness: { case_sensitive: false },
                    format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :password, length: { minimum: 8 }, allow_nil: true

  normalizes :email, with: ->(email) { email.to_s.strip.downcase }

  scope :operators, -> { where(operator: true) }

  def display_name
    name.presence || email.split("@").first
  end

  # What every other service is told about this user. Deliberately small: a
  # module has no business knowing the password digest or the OTP secret, and
  # the easiest way to guarantee that is to have one place that decides.
  def to_identity
    {
      id: id,
      email: email,
      name: display_name,
      operator: operator
    }
  end
end
