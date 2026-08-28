Rails.application.routes.draw do
  # Module-facing. Four verbs against /v1/{space}/{path}, plus a listing.
  # Everything about who is calling comes from the token and the Router's domain
  # header, never from the path: a module has no field in which to name another
  # module's files.
  scope "/v1" do
    # An address for an object, instead of the object.
    #
    # Declared before the generic `:space` routes below, which would otherwise
    # read "urls" as a space name and answer 404 for a space nobody has.
    #
    # This is what lets a module stay out of its own byte path for private
    # files, the way the public path already does for public ones: the module
    # decides whether this caller may have the file, and then sends them to the
    # object store rather than fetching it and copying it out.
    get "urls/:space/*path", to: "files#signed_url", format: false

    get ":space", to: "files#index"
    get ":space/*path", to: "files#show", format: false
    # The router has no head DSL method; it would collide with the controller
    # helper of the same name. via: :head is the supported spelling.
    match ":space/*path", to: "files#describe", via: :head, format: false
    put ":space/*path", to: "files#create", format: false
    delete ":space/*path", to: "files#destroy", format: false
  end

  # The public space, without a token, so that an image can be a URL a browser
  # loads rather than bytes a module proxies. The module is named in the path
  # because there is no token to name it; see PublicFilesController for why that
  # is safe for this space and only this space.
  get "public/:module_name/*path", to: "public_files#show", format: false, as: :public_file

  # Orchestrator-facing, behind the admin token. A module cannot register
  # itself, because grants are approved by an operator before they exist.
  namespace :admin do
    get "modules", to: "modules#index"
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
