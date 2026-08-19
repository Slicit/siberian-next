# frozen_string_literal: true

# What the Mobile service needs to know: which app belongs to which domain,
# what it is allowed to do natively, which modules contribute to it, and what
# is in the build queue.
class CreateMobileSchema < ActiveRecord::Migration[8.1]
  def change
    # One app per domain. The domain is the tenant boundary everywhere else in
    # this system, so it is the key here too.
    create_table :mobile_apps do |t|
      t.string :domain, null: false
      t.string :name, null: false
      t.string :bundle_identifier, null: false
      t.string :version, null: false, default: "1.0.0"
      # Incremented by the builder, never by hand: two builds with the same
      # build number are two artifacts a store cannot tell apart.
      t.integer :build_number, null: false, default: 0
      t.string :primary_color
      t.string :icon_path
      t.json :settings, null: false, default: {}
      t.timestamps
    end
    add_index :mobile_apps, :domain, unique: true
    add_index :mobile_apps, :bundle_identifier, unique: true

    # Which native capabilities this app is built with. A row exists only if an
    # operator decided something: absence is the default, and the default is off.
    create_table :app_capabilities do |t|
      t.references :mobile_app, null: false, foreign_key: true
      t.string :capability, null: false
      t.boolean :enabled, null: false, default: true
      # "operator" when somebody switched it on, "module" when it was approved
      # as part of installing something that requires it. Kept because the two
      # answer different questions when somebody asks why the app can do this.
      t.string :source, null: false, default: "operator"
      t.json :settings, null: false, default: {}
      t.timestamps
    end
    add_index :app_capabilities, %i[mobile_app_id capability], unique: true

    # Registered by the Orchestrator at install time, the same shape the Storage
    # and Mailer services use. A module cannot register itself: what it ships
    # natively is approved by an operator before it exists here.
    create_table :module_registrations do |t|
      t.string :module_name, null: false
      t.string :module_uuid, null: false
      t.string :token_digest, null: false
      t.string :native_entry
      t.string :fallback, null: false, default: "webview"
      t.string :base_route
      t.string :origin
      t.datetime :revoked_at
      t.timestamps
    end
    add_index :module_registrations, :module_name, unique: true
    add_index :module_registrations, :token_digest, unique: true

    # One per feature capability a module renders natively. A capability with no
    # row here falls back to a WebView on the module's own UI.
    create_table :module_screens do |t|
      t.references :module_registration, null: false, foreign_key: true
      t.string :capability, null: false
      t.string :component, null: false
      t.string :title
      t.string :icon
      t.timestamps
    end
    add_index :module_screens, %i[module_registration_id capability], unique: true

    # What a module said it needs. A request, never a switch: whether it is on
    # is decided per app, in app_capabilities.
    create_table :module_requirements do |t|
      t.references :module_registration, null: false, foreign_key: true
      t.string :capability, null: false
      t.timestamps
    end
    add_index :module_requirements, %i[module_registration_id capability], unique: true

    # The queue. One row per requested build, claimed with FOR UPDATE SKIP
    # LOCKED exactly as the mail queue is, so a second builder can be added
    # without either of them learning about the other.
    create_table :builds do |t|
      t.references :mobile_app, null: false, foreign_key: true
      t.string :domain, null: false
      t.string :platform, null: false
      t.string :state, null: false, default: "queued"
      t.integer :attempts, null: false, default: 0
      t.datetime :next_attempt_at
      t.datetime :claimed_at
      t.datetime :started_at
      t.datetime :finished_at
      t.string :requested_by
      t.string :last_error
      # Where the artifact landed in Storage. Null until something came out.
      t.string :artifact_path
      t.bigint :artifact_bytes
      t.text :log
      # The manifest the builder worked from, kept so a build can be explained
      # after the configuration behind it has changed.
      t.json :configuration, null: false, default: {}
      t.datetime :acknowledged_at
      t.timestamps
    end
    add_index :builds, %i[state next_attempt_at]
    add_index :builds, %i[mobile_app_id created_at]

    # The Mobile service holds one credential for Storage, the same way a module
    # does, so app artifacts land in the same place as everything else and are
    # governed by the same quotas. A domain that has filled its storage cannot
    # store a new build of its app, and the refusal says which limit stopped it.
    create_table :service_credentials do |t|
      t.string :service, null: false
      t.string :token, null: false
      t.timestamps
    end
    add_index :service_credentials, :service, unique: true

    # One per attempt, so a build that succeeded on the third try still says
    # what happened on the first two.
    create_table :build_attempts do |t|
      t.references :build, null: false, foreign_key: true
      t.integer :number, null: false
      t.string :outcome, null: false
      t.integer :duration_ms
      t.text :detail
      t.datetime :attempted_at, null: false
      t.timestamps
    end
    add_index :build_attempts, %i[build_id number], unique: true
  end
end
