Rails.application.routes.draw do
  # The one login screen in the system.
  get "login", to: "sessions#new", as: :login
  post "login", to: "sessions#create"
  delete "logout", to: "sessions#destroy", as: :logout
  get "logout", to: "sessions#destroy"

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

    resources :roles, only: %i[index create update destroy]

    # Delivers catalogue permissions added since a seeded role was created.
    # Idempotent, so the Orchestrator can call it on every reconcile.
    post "roles/reconcile", to: "roles#reconcile"
  end

  get "up", to: "rails/health#show", as: :rails_health_check
  root "sessions#new"
end
