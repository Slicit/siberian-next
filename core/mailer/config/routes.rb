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

  # Mail the core itself sends. The same queue as a module's, reached with a
  # service token rather than a module one.
  scope "/core" do
    post "messages", to: "core/messages#create"
    get "messages", to: "core/messages#index"
  end

  namespace :admin do
    get "modules", to: "modules#index"
    post "modules", to: "modules#create"
    delete "modules/:module_name", to: "modules#destroy"
    get "queue", to: "modules#queue"

    # Putting a dead message back, from the Backoffice.
    #
    # The module-facing retry needs the sending module's token. An operator
    # looking at a stuck queue does not have one and should not: this is the
    # same operation reached through the door the Orchestrator already uses.
    post "queue/:id/retry", to: "modules#retry_message"
  end

  get "up", to: "rails/health#show", as: :rails_health_check
end
