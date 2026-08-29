Rails.application.routes.draw do
  # The one login screen in the system.
  get "login", to: "sessions#new", as: :login
  post "login", to: "sessions#create"
  delete "logout", to: "sessions#destroy", as: :logout

  # Getting back in without a password. Same door as the sign-in form, because
  # the person is looking at a page rather than holding a token.
  get "forgot", to: "passwords#new", as: :forgot
  post "forgot", to: "passwords#create"
  get "reset", to: "passwords#edit", as: :reset
  post "reset", to: "passwords#update"
  get "logout", to: "sessions#destroy"

  # The app's own door.
  #
  # Under /-/ because that prefix is reserved by the Router for core paths, so
  # it can never collide with a module base route or a page a CMS publishes.
  # JSON throughout: the caller is a phone, not a browser.
  namespace :app, path: "-/auth" do
    post "register", to: "sessions#create_account"
    post "sign-in", to: "sessions#create"
    # Getting back in without one. Public, unauthenticated, and throttled,
    # because it sends an email to any address it is given.
    post "forgot", to: "passwords#create"
    get "reset", to: "passwords#show"
    post "reset", to: "passwords#update"
    delete "sign-out", to: "sessions#destroy"
    get "verify", to: "sessions#verify"
    get "me", to: "sessions#show"
    get "devices", to: "sessions#devices"
    delete "devices/:id", to: "sessions#revoke_device"
  end

  # How everything else asks who is signed in and what they may do. The caller
  # forwards the browser cookie; only this service can read it.
  namespace :internal do
    get "session", to: "sessions#show"
    delete "session", to: "sessions#destroy"

    # A fresh answer for one question, for the handful of actions where a
    # cached set is not good enough.
    post "authorize", to: "sessions#authorize_action"

    resources :users, only: %i[index show create update destroy] do
      member do
        post "roles", to: "users#assign_role"
        delete "roles", to: "users#unassign_role"
        post "grants", to: "users#grant"
        delete "grants", to: "users#revoke"
      end
    end

    # The people a domain's app is for. Operator-facing, which is why it is
    # here and not on the app's own door.
    get "app-users", to: "app_users#index"
    post "app-users", to: "app_users#create"
    patch "app-users/:id", to: "app_users#update"
    post "app-users/:id/deactivate", to: "app_users#deactivate"
    post "app-users/:id/reactivate", to: "app_users#reactivate"
    delete "app-users/:id/devices/:device_id", to: "app_users#revoke_device"
    patch "app-settings", to: "app_users#settings"

    resources :roles, only: %i[index create update destroy]

    # Delivers catalogue permissions added since a seeded role was created.
    # Idempotent, so the Orchestrator can call it on every reconcile.
    post "roles/reconcile", to: "roles#reconcile"
  end

  get "up", to: "rails/health#show", as: :rails_health_check
  root "sessions#new"
end
