# frozen_string_literal: true

# Database passwords are stored so they can be served again: a module container
# restarts and asks for its credentials, and several replicas of one module must
# get the same answer. Stored means encrypted.
#
# Keys come from the environment. The development defaults are obviously fake so
# nobody mistakes them for secrets, and a real deployment that forgets to set
# them fails loudly rather than quietly encrypting with a published key.
Rails.application.configure do
  config.active_record.encryption.primary_key =
    ENV.fetch("SIBERIAN_ENCRYPTION_PRIMARY_KEY", "development_primary_key_not_a_secret_0000")
  config.active_record.encryption.deterministic_key =
    ENV.fetch("SIBERIAN_ENCRYPTION_DETERMINISTIC_KEY", "development_deterministic_key_not_secret_0")
  config.active_record.encryption.key_derivation_salt =
    ENV.fetch("SIBERIAN_ENCRYPTION_SALT", "development_salt_not_a_secret_00000000000")

  if Rails.env.production? && ENV["SIBERIAN_ENCRYPTION_PRIMARY_KEY"].blank?
    raise "SIBERIAN_ENCRYPTION_PRIMARY_KEY must be set in production; stored credentials depend on it"
  end
end
