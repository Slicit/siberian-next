# frozen_string_literal: true

# A credential this service holds for another one.
#
# One row, for Storage. Kept rather than re-requested because registering twice
# would mint a second token and leave the first one valid, and a credential
# nobody is using is a credential nobody is watching.
class ServiceCredential < ApplicationRecord
  validates :service, presence: true, uniqueness: true
  validates :token, presence: true
end
