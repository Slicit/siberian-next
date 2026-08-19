Rails.application.routes.draw do
  # Module-facing.
  #
  # A module collects credentials for its own database and then talks to
  # Postgres directly: this service is not in that path, and should not be. What
  # it does stay in the path of is reading somebody else's tables, because that
  # is the only way an audit trail can exist at all.
  scope "/v1" do
    get "credentials", to: "credentials#show"
    get "databases", to: "credentials#index"
    get "system", to: "system_tables#index"
    get "system/:database/:table", to: "system_tables#show"
    get "audit", to: "audit#index"
  end

  # Orchestrator-facing, behind the admin token. A module cannot grant itself
  # anything, which is the entire point of approving grants at install time.
  namespace :admin do
    post "modules", to: "modules#create"
    post "modules/:module_name/databases", to: "modules#provision"
    post "modules/:module_name/table_grants", to: "modules#grant_tables"
    post "modules/:module_name/rotate", to: "modules#rotate"
    delete "modules/:module_name", to: "modules#destroy"
    get "audit", to: "audit#index"
  end

  get "up", to: "rails/health#show", as: :rails_health_check
end
