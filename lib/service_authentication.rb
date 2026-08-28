# frozen_string_literal: true

require "service_identity"

module Siberian
  # The callee half: a controller says which services may call it.
  #
  #   class Admin::ModulesController < ApplicationController
  #     include Siberian::ServiceAuthentication
  #     permit_services :orchestrator
  #   end
  #
  # The point is that the list is per controller rather than per service. The
  # Orchestrator has a reason to register a module with Storage; nothing else
  # does, and before this every service could, because they all held the same
  # token.
  #
  # A controller that includes this and names nobody permits nobody, which is
  # the right way round: forgetting the declaration closes the door rather than
  # opening it.
  module ServiceAuthentication
    extend ActiveSupport::Concern

    included do
      class_attribute :permitted_services, default: [].freeze
      before_action :authenticate_service!
    end

    class_methods do
      def permit_services(*names)
        self.permitted_services = names.map(&:to_s).freeze
      end
    end

    private

    # The caller's name, once authenticated. Worth having beyond the check
    # itself: an audit line saying which service did something is the thing
    # that was impossible when they all presented the same token.
    attr_reader :calling_service

    def authenticate_service!
      caller_name = Siberian::ServiceIdentity.identify(bearer_token)

      if caller_name == Siberian::ServiceIdentity::LEGACY
        # The deployment has not been given per pair tokens yet. Accepted, so
        # that upgrading the code and upgrading the environment can be two
        # separate moments, but said out loud every time rather than degrading
        # quietly into the behaviour this replaced.
        Rails.logger.warn(
          "#{self.class.name}: accepted the shared admin token. Set SIBERIAN_CALLERS " \
          "on this service to name who may call it."
        )
        @calling_service = "unverified"
        return
      end

      if caller_name.nil?
        return render_service_refusal("this endpoint is for core services, and that is not a token one holds")
      end

      unless permitted_services.include?(caller_name)
        # Named in the log rather than in the response. The caller learning
        # which services would have been allowed is not useful to a legitimate
        # one and is useful to everybody else.
        Rails.logger.warn("#{self.class.name}: refused #{caller_name}, permits #{permitted_services.join(', ')}")
        return render_service_refusal("#{caller_name} is not permitted here")
      end

      @calling_service = caller_name
    end

    def bearer_token
      header = request.headers["Authorization"].to_s
      return nil unless header.start_with?("Bearer ")

      header.delete_prefix("Bearer ").strip
    end

    def render_service_refusal(message)
      render json: { error: message }, status: :unauthorized
    end
  end
end
