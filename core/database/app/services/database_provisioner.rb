# frozen_string_literal: true

# Creates the database and role for one (module, domain, logical name) triple,
# and records it.
#
# Idempotent, because installation retries and because an operator adding a
# domain provisions every installed module against it.
class DatabaseProvisioner
  def initialize(admin: PostgresAdmin.new)
    @admin = admin
  end

  def call(registration, domain:, logical_name: "primary")
    # Before the early return, not after. A cluster provisioned before the
    # hardening existed would otherwise never get it, which is exactly the case
    # that found the gap.
    @admin.harden_cluster!

    existing = registration.provisioned_databases.find_by(domain: domain, logical_name: logical_name)

    if existing&.ready?
      # The role may be locked out from a previous uninstall. Handing back
      # credentials that cannot log in is worse than not handing them back at
      # all, because the failure surfaces inside the module as a wrong password.
      @admin.reactivate(role_name: existing.role_name, password: existing.encrypted_password)

      AuditEvent.record!(
        module_name: registration.module_name,
        domain: domain,
        action: "database.reactivated",
        subject: existing.database_name,
        detail: "login restored for an existing database"
      )

      return existing
    end

    names = ProvisionedDatabase.names_for(registration.module_name, domain, logical_name)

    # A suspended record keeps its password, so reinstalling gives the module
    # the same credentials back rather than silently invalidating any it cached.
    password = existing&.encrypted_password.presence || SecureRandom.urlsafe_base64(24)

    @admin.provision(
      database_name: names[:database_name],
      role_name: names[:role_name],
      password: password
    )

    record = existing || registration.provisioned_databases.build(domain: domain, logical_name: logical_name)
    record.assign_attributes(
      database_name: names[:database_name],
      role_name: names[:role_name],
      encrypted_password: password,
      state: "ready"
    )
    record.save!

    AuditEvent.record!(
      module_name: registration.module_name,
      domain: domain,
      action: "database.provisioned",
      subject: names[:database_name],
      detail: "role #{names[:role_name]} created and granted CONNECT"
    )

    record
  rescue PostgresAdmin::Error => e
    AuditEvent.record!(
      module_name: registration.module_name,
      domain: domain,
      action: "database.provision_failed",
      outcome: "failed",
      detail: e.message
    )
    raise
  end

  # A new password, and the old one stops working. Used when a credential is
  # suspected of having leaked, which is the only time anyone wants this.
  def rotate(provisioned)
    password = SecureRandom.urlsafe_base64(24)
    @admin.rotate_password(role_name: provisioned.role_name, password: password)
    provisioned.update!(encrypted_password: password, rotated_at: Time.current)

    AuditEvent.record!(
      module_name: provisioned.module_registration.module_name,
      domain: provisioned.domain,
      action: "credentials.rotated",
      subject: provisioned.database_name,
      detail: "previous password invalidated"
    )

    provisioned
  end

  # Removing a module does not remove its data. Locking the role out is the
  # strongest move that is still safe to undo, and reinstalling a module to
  # find its tables gone is a far worse surprise than a database left behind.
  def suspend(provisioned)
    @admin.revoke_login(role_name: provisioned.role_name)
    provisioned.update!(state: "suspended")

    AuditEvent.record!(
      module_name: provisioned.module_registration.module_name,
      domain: provisioned.domain,
      action: "database.suspended",
      subject: provisioned.database_name,
      detail: "role can no longer log in; data left intact"
    )

    provisioned
  end
end
