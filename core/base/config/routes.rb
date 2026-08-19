Rails.application.routes.draw do
  root "home#show"

  # One capability, framed. The trailing wildcard lets a module page be deep
  # linked rather than always opening at its front door.
  get "m/:id", to: "modules#show", as: :module_frame
  get "m/:id/*rest", to: "modules#show", format: false

  get "up", to: "rails/health#show", as: :rails_health_check
end
