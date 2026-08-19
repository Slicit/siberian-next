Rails.application.routes.draw do
  # Module-facing. Four verbs against /v1/{space}/{path}, plus a listing.
  # Everything about who is calling comes from the token and the Router's domain
  # header, never from the path: a module has no field in which to name another
  # module's files.
  scope "/v1" do
    get ":space", to: "files#index"
    get ":space/*path", to: "files#show", format: false
    # The router has no head DSL method; it would collide with the controller
    # helper of the same name. via: :head is the supported spelling.
    match ":space/*path", to: "files#describe", via: :head, format: false
    put ":space/*path", to: "files#create", format: false
    delete ":space/*path", to: "files#destroy", format: false
  end

  # Orchestrator-facing, behind the admin token. A module cannot register
  # itself, because grants are approved by an operator before they exist.
  namespace :admin do
    post "modules", to: "modules#create"
    post "modules/:module_name/buckets", to: "modules#provision"
    delete "modules/:module_name", to: "modules#destroy"

    # Quotas, for the Backoffice. Three levels because three questions get
    # asked: the default for a new bucket, one bucket, and the shared pool.
    get "quotas", to: "quotas#show"
    patch "quotas", to: "quotas#update"
    patch "quotas/domains/:domain", to: "quotas#update_domain", constraints: { domain: %r{[^/]+} }, format: false
    patch "quotas/buckets/:id", to: "quotas#update_bucket"
    post "quotas/recalculate", to: "quotas#recalculate"
  end

  get "up", to: "rails/health#show", as: :rails_health_check
end
