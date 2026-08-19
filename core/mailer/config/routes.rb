Rails.application.routes.draw do
  # Module-facing. A module hands over a message and stops thinking about it,
  # then polls for outcomes and acknowledges them. Everything is scoped to the
  # calling module and the Router's domain header.
  scope "/v1" do
    post "messages", to: "messages#create"
    get "messages", to: "messages#index"
    post "messages/ack", to: "messages#acknowledge_many"
    get "messages/:id", to: "messages#show"
    delete "messages/:id", to: "messages#destroy"
    post "messages/:id/ack", to: "messages#acknowledge"
    post "messages/:id/retry", to: "messages#retry_message"
    get "stats", to: "messages#stats"
  end

  namespace :admin do
    post "modules", to: "modules#create"
    delete "modules/:module_name", to: "modules#destroy"
    get "queue", to: "modules#queue"
  end

  get "up", to: "rails/health#show", as: :rails_health_check
end
