# frozen_string_literal: true

require "digest"

# Sends an app account the link that proves it can read its own address.
#
# One place, because two paths create an account: somebody signing up, and an
# operator adding one. An operator-created account that could never be verified
# would be permanently marked unverified through no fault of the person using
# it, which is worse than not having the flag.
class AppVerification
  def initialize(mailer: Siberian::CoreMailClient.new(logger: Rails.logger))
    @mailer = mailer
  end

  def send_to(account, domain:)
    token = account.start_verification!

    @mailer.deliver(
      domain: domain,
      to: account.email,
      subject: "Confirm your email address",
      text_body: <<~BODY,
        Somebody created an account for #{account.email} on #{domain}.

        https://#{domain}/-/auth/verify?token=#{token}

        You can use the app either way. This only confirms the address is
        yours, which is what lets anybody rely on it.
      BODY
      # Keyed on the token, so asking again sends a new link rather than being
      # deduplicated into the old one, which would be a dead link and no way to
      # get a live one.
      idempotency_key: "app-verification-#{account.id}-#{Digest::SHA256.hexdigest(token)[0, 12]}"
    )

    token
  end
end
