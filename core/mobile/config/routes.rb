Rails.application.routes.draw do
  # Orchestrator-facing, behind the admin token. Everything an operator does
  # arrives here through the Backoffice: this service has no UI of its own.
  namespace :admin do
    get "apps", to: "apps#index"
    get "apps/:domain", to: "apps#show", constraints: { domain: %r{[^/]+} }, format: false
    put "apps/:domain", to: "apps#upsert", constraints: { domain: %r{[^/]+} }, format: false
    delete "apps/:domain", to: "apps#destroy", constraints: { domain: %r{[^/]+} }, format: false
    patch "apps/:domain/capabilities/:capability", to: "apps#update_capability",
          constraints: { domain: %r{[^/]+} }, format: false

    get "modules", to: "modules#index"
    post "modules", to: "modules#create"
    delete "modules/:module_name", to: "modules#destroy"

    get "builds", to: "builds#index"
    post "builds", to: "builds#create"
    get "builds/:id", to: "builds#show"
    post "builds/:id/cancel", to: "builds#cancel"
  end

  # The builder's end, behind a token of its own. A different trust level gets
  # a different credential: this one runs third-party code.
  namespace :internal do
    post "builds/claim", to: "builds#claim"
    patch "builds/:id", to: "builds#update"
    post "builds/:id/artifact", to: "builds#artifact"
  end

  get "up", to: "rails/health#show", as: :rails_health_check
end
