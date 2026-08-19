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

  resources :domains, only: %i[index create update destroy]
  get "interfaces", to: "interfaces#index", as: :interfaces
  get "activity", to: "activities#index", as: :activity

  get "up", to: "rails/health#show", as: :rails_health_check
end
