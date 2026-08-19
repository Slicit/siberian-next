Rails.application.routes.draw do
  # The one login screen in the system.
  get "login", to: "sessions#new", as: :login
  post "login", to: "sessions#create"
  delete "logout", to: "sessions#destroy", as: :logout
  get "logout", to: "sessions#destroy"

  # How everything else asks who is signed in. The caller forwards the
  # browser's cookie; only this service can read it.
  namespace :internal do
    get "session", to: "sessions#show"
    delete "session", to: "sessions#destroy"
    resources :users, only: %i[index show]
  end

  get "up", to: "rails/health#show", as: :rails_health_check
  root "sessions#new"
end
