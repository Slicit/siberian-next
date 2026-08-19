Rails.application.routes.draw do
  root "dashboard#show"

  # Modules are addressed by name rather than by id: the name is what an
  # operator knows, and it is unique by contract.
  get "modules", to: "modules#index", as: :modules
  get "modules/:name", to: "modules#show", as: :module
  post "modules/:name/refresh", to: "modules#refresh", as: :refresh_module
  delete "modules/:name", to: "modules#destroy"

  post "routes/reconcile", to: "routes#reconcile", as: :reconcile_routes

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
  get "interfaces", to: "interfaces#index", as: :interfaces
  get "activity", to: "activities#index", as: :activity

  # What the Base App reads to build its shell. The shell never learns a
  # container name, a uuid, or a network: a module is a title, an area, a URL.
  namespace :internal do
    get "capabilities", to: "capabilities#index"
  end

  get "up", to: "rails/health#show", as: :rails_health_check
end
