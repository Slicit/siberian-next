Rails.application.routes.draw do
  root "home#show"

  # One capability, framed. The trailing wildcard lets a module page be deep
  # linked rather than always opening at its front door.
  get "m/:id", to: "modules#show", as: :module_frame
  get "m/:id/*rest", to: "modules#show", format: false

  # The phone app for this domain. One app, one domain, and the domain is the
  # one the Router put on the request rather than one anybody names.
  get "app", to: "phone_app#show", as: :phone_app
  post "app/suggest", to: "phone_app#suggest", as: :suggest_phone_app
  patch "app", to: "phone_app#apply", as: :apply_phone_app
  patch "app/capabilities/:capability", to: "phone_app#update_capability", as: :phone_app_capability
  post "app/splash", to: "phone_app#upload_splash", as: :phone_app_splash
  delete "app/splash", to: "phone_app#remove_splash"
  post "app/build", to: "phone_app#build", as: :build_phone_app

  # The exported web build, served from this domain so the app owner can look
  # at what they are about to ship without leaving the page they built it on.
  # Proxied rather than linked: the export lives inside the Mobile service and
  # nothing outside the core has a route to it.
  get "app/preview", to: "phone_app#preview", as: :preview_phone_app
  get "app/preview/*path", to: "phone_app#preview", format: false

  get "up", to: "rails/health#show", as: :rails_health_check
end
