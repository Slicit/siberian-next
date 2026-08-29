Rails.application.routes.draw do
  root "dashboard#show"

  # Modules are addressed by name rather than by id: the name is what an
  # operator knows, and it is unique by contract.
  get "modules", to: "modules#index", as: :modules
  get "modules/:name", to: "modules#show", as: :module
  post "modules/:name/refresh", to: "modules#refresh", as: :refresh_module
  delete "modules/:name", to: "modules#destroy"

  post "routes/reconcile", to: "routes#reconcile", as: :reconcile_routes

  # Routing plus every other piece of state that is derived once and can go
  # stale: service registrations and the permission catalogue.
  post "state/reconcile", to: "state#reconcile", as: :reconcile_state

  get "catalog", to: "catalog#index", as: :catalog
  get "catalog/:name", to: "catalog#show", as: :catalog_entry
  post "catalog/:name/install", to: "catalog#create", as: :install_catalog_entry

  # People and roles. Reading and changing are separate permissions, so the
  # routes are the same page and the controller decides.
  get "people", to: "people#index", as: :people
  post "people", to: "people#create"
  get "people/:id", to: "people#show", as: :person
  patch "people/:id", to: "people#update"
  post "people/:id/deactivate", to: "people#deactivate", as: :deactivate_person
  post "people/:id/roles", to: "people#assign_role", as: :person_roles
  delete "people/:id/roles", to: "people#unassign_role"
  post "people/:id/grants", to: "people#grant", as: :person_grants
  delete "people/:id/grants", to: "people#revoke"

  resources :roles, only: %i[index create update destroy]

  resources :domains, only: %i[index create update destroy]
  patch "domains/:id/storage", to: "domains#update_storage", as: :domain_storage
  get "storage", to: "storage#index", as: :storage
  patch "storage", to: "storage#update"
  patch "storage/domain", to: "storage#update_domain", as: :update_domain_storage
  patch "storage/bucket", to: "storage#update_bucket", as: :update_bucket_storage
  post "storage/recalculate", to: "storage#recalculate", as: :recalculate_storage

  # The phone apps. One per domain, and the queue that builds them.
  get "mobile", to: "mobile#index", as: :mobile
  # Addressed by the domain record rather than the hostname, like every other
  # domain route here. A hostname in a path segment is a dot in a place Rails
  # reserves for a format.
  get "mobile/:id", to: "mobile#show", as: :mobile_app
  patch "mobile/:id", to: "mobile#save"
  patch "mobile/:id/capabilities/:capability", to: "mobile#update_capability", as: :mobile_capability
  get "mobile/:id/preview", to: "mobile#preview", as: :mobile_preview
  get "mobile/:id/preview/*path", to: "mobile#preview", format: false
  post "mobile/:id/splash", to: "mobile#upload_splash", as: :mobile_splash
  delete "mobile/:id/splash", to: "mobile#remove_splash"
  post "mobile/:id/build", to: "mobile#build", as: :build_mobile_app
  post "mobile/:id/builds/:build_id/cancel", to: "mobile#cancel", as: :cancel_mobile_build

  # The people a domain's app is for.
  #
  # A separate page from People, and deliberately: those are accounts that run
  # the system, these are accounts that use one domain's product, and a single
  # list holding both would invite treating them as one thing. Addressed by the
  # domain record, like every other per-domain route here.
  get "app-users", to: "app_users#index", as: :app_users
  get "app-users/:id", to: "app_users#show", as: :domain_app_users
  post "app-users/:id", to: "app_users#create"
  patch "app-users/:id/registration", to: "app_users#registration", as: :app_registration
  post "app-users/:id/accounts/:account_id/active", to: "app_users#set_active", as: :app_user_active
  patch "app-users/:id/accounts/:account_id/password", to: "app_users#set_password",
        as: :app_user_password
  delete "app-users/:id/accounts/:account_id/devices/:device_id", to: "app_users#revoke_device",
         as: :app_user_device

  # What the system has been doing, for the two services whose work is
  # invisible until somebody asks: mail that did not arrive, and a module
  # reading somebody else's tables.
  get "queue", to: "queue#index", as: :queue
  post "queue/:id/retry", to: "queue#retry_message", as: :retry_message
  get "audit-trail", to: "queue#audit", as: :audit

  get "interfaces", to: "interfaces#index", as: :interfaces
  get "activity", to: "activities#index", as: :activity

  # What the Base App reads to build its shell. The shell never learns a
  # container name, a uuid, or a network: a module is a title, an area, a URL.
  namespace :internal do
    get "capabilities", to: "capabilities#index"
    get "interfaces/:name", to: "interfaces#show", constraints: { name: %r{[^/]+} }, format: false
  end

  get "up", to: "rails/health#show", as: :rails_health_check
end
