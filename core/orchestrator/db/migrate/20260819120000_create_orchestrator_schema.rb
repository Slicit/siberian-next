# frozen_string_literal: true

# The Orchestrator's own record of what is installed. The engine is the source
# of truth for what is running; this is the source of truth for what was asked
# for, what was granted, and by whom.
class CreateOrchestratorSchema < ActiveRecord::Migration[8.1]
  def change
    # A domain the system serves. Containers are shared across all of them;
    # data is not (LOGBOOK.md, "Isolate data, not runners").
    create_table :domains do |t|
      t.string :hostname, null: false
      t.string :label
      t.boolean :primary, null: false, default: false
      t.timestamps
    end
    add_index :domains, :hostname, unique: true

    # One row per installation. Named InstalledModule because Module is taken
    # by Ruby itself, and shadowing it inside a Rails app is a bad trade.
    create_table :installed_modules do |t|
      t.string :uuid, null: false
      t.string :name, null: false
      t.string :version, null: false
      t.string :title
      t.text :description
      # pending, installing, running, degraded, stopped, failed, removing
      t.string :status, null: false, default: "pending"
      t.string :base_route
      t.string :origin
      t.string :entry_service
      t.string :network_name
      t.json :manifest, null: false, default: {}
      t.text :last_error
      t.datetime :installed_at
      t.timestamps
    end
    add_index :installed_modules, :uuid, unique: true
    add_index :installed_modules, :name, unique: true
    add_index :installed_modules, :status

    # What the engine was asked to create. engine_id is the engine's own
    # identifier, deliberately not treated as stable across engines.
    create_table :module_containers do |t|
      t.references :installed_module, null: false, foreign_key: true
      t.string :service, null: false
      t.string :name, null: false
      t.string :image, null: false
      t.string :role, null: false
      t.integer :internal_port
      t.string :engine_id
      t.string :state, null: false, default: "absent"
      t.datetime :state_checked_at
      t.timestamps
    end
    add_index :module_containers, :name, unique: true
    add_index :module_containers, %i[installed_module_id service], unique: true

    # What a module offers the rest of the system. The Base App reads this to
    # decide what appears in which area.
    create_table :capabilities do |t|
      t.references :installed_module, null: false, foreign_key: true
      t.string :capability_id, null: false
      t.string :area, null: false
      t.string :title, null: false
      t.string :path, null: false
      t.string :icon
      t.json :accepts, null: false, default: []
      t.integer :position, null: false, default: 0
      t.timestamps
    end
    add_index :capabilities, :capability_id, unique: true
    add_index :capabilities, :area

    # A capability a module would like to use if something provides it. Kept
    # separate from provides so discovery can match the two sides without
    # either module naming the other.
    create_table :capability_requests do |t|
      t.references :installed_module, null: false, foreign_key: true
      t.string :capability_id, null: false
      t.boolean :optional, null: false, default: true
      t.timestamps
    end
    add_index :capability_requests, %i[installed_module_id capability_id], unique: true,
                                    name: "index_capability_requests_on_module_and_capability"

    # Everything an operator approved at install time. Nothing outside this
    # table is reachable by the module.
    create_table :grants do |t|
      t.references :installed_module, null: false, foreign_key: true
      t.string :kind, null: false          # database, storage, mail, module
      t.string :target                     # database name, module name, or nil
      t.string :access                     # owner, read, write, send
      t.string :scope, null: false, default: "per_domain"
      t.json :details, null: false, default: {}
      t.datetime :approved_at
      t.timestamps
    end
    add_index :grants, %i[installed_module_id kind]

    # A provisioned resource that belongs to one (module, domain) pair. This is
    # where the isolation rule becomes rows.
    create_table :provisions do |t|
      t.references :installed_module, null: false, foreign_key: true
      t.references :domain, null: false, foreign_key: true
      t.string :kind, null: false          # database, storage
      t.string :identifier, null: false    # database name, or bucket name
      t.string :state, null: false, default: "pending"
      t.json :details, null: false, default: {}
      t.timestamps
    end
    add_index :provisions, %i[installed_module_id domain_id kind], unique: true,
                           name: "index_provisions_on_module_domain_kind"

    # An append-only record of what the Orchestrator did. Installing a module
    # touches an engine, a database, and a router; when it goes wrong, the
    # question is always which step.
    create_table :activities do |t|
      t.references :installed_module, foreign_key: true
      t.string :action, null: false
      t.string :outcome, null: false, default: "started"
      t.text :detail
      t.json :context, null: false, default: {}
      t.timestamps
    end
    add_index :activities, :created_at
  end
end
