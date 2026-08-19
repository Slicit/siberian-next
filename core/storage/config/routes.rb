Rails.application.routes.draw do
  # Module-facing. Four verbs against /v1/{space}/{path}, plus a listing.
  # Everything about who is calling comes from the token and the Router's domain
  # header, never from the path: a module has no field in which to name another
  # module's files.
  scope "/v1" do
    get ":space", to: "files#index"
    get ":space/*path", to: "files#show", format: false
    head ":space/*path", to: "files#describe", format: false
    put ":space/*path", to: "files#create", format: false
    delete ":space/*path", to: "files#destroy", format: false
  end

  # Orchestrator-facing, behind the admin token. A module cannot register
  # itself, because grants are approved by an operator before they exist.
  namespace :admin do
    post "modules", to: "modules#create"
    post "modules/:module_name/buckets", to: "modules#provision"
    delete "modules/:module_name", to: "modules#destroy"
  end

  get "up", to: "rails/health#show", as: :rails_health_check
end
