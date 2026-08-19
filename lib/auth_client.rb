# frozen_string_literal: true

require "net/http"
require "json"
require_relative "permissions"

module Siberian
  # Asks Auth who is signed in and what they may do.
  #
  # Shared by the Backoffice and the Base App rather than written twice, for the
  # same reason the matching rules are shared: two services disagreeing about
  # whether somebody may do a thing is the worst outcome available.
  #
  # Neither holds a password. Both forward the browser cookie to the one service
  # that can read it, exactly as a module does.
  class AuthClient
    # How long a resolved answer is reused without asking again.
    #
    # This is the whole performance and staleness trade, in one number. Zero
    # would make every page render a burst of network calls. Long would make a
    # withdrawn permission survive noticeably. Thirty seconds keeps a page
    # render at one call and puts a stated ceiling on how long a revocation can
    # take to bite, and anything that cannot tolerate that ceiling calls
    # `authorize?`, which never uses this cache.
    CACHE_TTL = 30

    Identity = Struct.new(:id, :email, :name, :active, :operator, :permissions, keyword_init: true) do
      def operator? = operator == true
      def allow?(permission) = permissions.allow?(permission)
      def deny?(permission) = permissions.deny?(permission)
      def any?(*list) = permissions.any?(*list)
    end

    def initialize(endpoint: ENV.fetch("SIBERIAN_AUTH_URL", "http://auth:3000"),
                   admin_token: ENV.fetch("SIBERIAN_ADMIN_TOKEN", "orchestrator_dev_only"),
                   cache: self.class.shared_cache)
      @endpoint = endpoint
      @admin_token = admin_token
      @cache = cache
    end

    # Process-wide and deliberately simple. A per-request cache would miss the
    # case this exists for, which is many checks inside one render.
    def self.shared_cache
      @shared_cache ||= { store: {}, mutex: Mutex.new }
    end

    def self.clear_cache!
      shared_cache[:mutex].synchronize { shared_cache[:store].clear }
    end

    # @return [Identity, nil]
    def identify(session_token)
      return nil if session_token.to_s.empty?

      cached = read_cache(session_token)
      return cached if cached

      payload = get("/internal/session", session: session_token)
      return nil unless payload && payload["authenticated"]

      identity = build(payload)
      write_cache(session_token, identity)
      identity
    end

    # A fresh answer for one question, never from cache.
    #
    # For the handful of actions where the cache ceiling is not acceptable:
    # removing a module, changing who can do what, anything an operator would
    # expect to stop working the instant it was withdrawn.
    def authorize?(session_token, permission)
      return false if session_token.to_s.empty?

      payload = post("/internal/authorize", { permission: permission }, session: session_token)
      payload ? payload["allowed"] == true : false
    end

    # Directory calls, for the interfaces that manage people. Behind the admin
    # token: this client trusts the service, and the service checks the person
    # before it calls.
    def users = get("/internal/users", admin: true)
    def user(id) = get("/internal/users/#{id}", admin: true)
    def roles = get("/internal/roles", admin: true)

    def create_user(attributes) = post("/internal/users", attributes, admin: true)
    def update_user(id, attributes) = patch("/internal/users/#{id}", attributes, admin: true)
    def set_user_active(id, active) = delete("/internal/users/#{id}?reactivate=#{active}", admin: true)

    def assign_role(id, role_id) = post("/internal/users/#{id}/roles", { role_id: role_id }, admin: true)
    def unassign_role(id, role_id) = delete("/internal/users/#{id}/roles?role_id=#{role_id}", admin: true)

    def grant(id, permission, effect: "allow", reason: nil)
      post("/internal/users/#{id}/grants", { permission: permission, effect: effect, reason: reason }, admin: true)
    end

    def revoke(id, permission, effect: "allow")
      delete("/internal/users/#{id}/grants?permission=#{CGI.escape(permission)}&effect=#{effect}", admin: true)
    end

    def create_role(attributes) = post("/internal/roles", attributes, admin: true)
    def update_role(id, attributes) = patch("/internal/roles/#{id}", attributes, admin: true)
    def delete_role(id, force: false) = delete("/internal/roles/#{id}?force=#{force}", admin: true)

    private

    def build(payload)
      user = payload.fetch("user")
      Identity.new(
        id: user["id"],
        email: user["email"],
        name: user["name"],
        active: user["active"],
        operator: user["operator"],
        permissions: Permissions::Set.new(payload["permissions"] || [], denied: payload["denied"] || [])
      )
    end

    def read_cache(token)
      @cache[:mutex].synchronize do
        entry = @cache[:store][token]
        next nil if entry.nil?
        # Expired entries are dropped rather than left to accumulate: this store
        # has no other eviction, and a signed-out browser never returns for its
        # row.
        if entry[:at] + CACHE_TTL < Time.now.to_i
          @cache[:store].delete(token)
          next nil
        end

        entry[:identity]
      end
    end

    def write_cache(token, identity)
      @cache[:mutex].synchronize do
        @cache[:store][token] = { identity: identity, at: Time.now.to_i }
        # A crude ceiling, because an unbounded hash in a long-lived process is
        # a leak with a nicer name.
        @cache[:store].shift while @cache[:store].size > 2_000
      end
    end

    def get(path, session: nil, admin: false)
      request = Net::HTTP::Get.new(URI.join(@endpoint, path))
      send_request(request, session: session, admin: admin)
    end

    def post(path, body, session: nil, admin: false)
      request = Net::HTTP::Post.new(URI.join(@endpoint, path))
      request.body = JSON.generate(body)
      request["Content-Type"] = "application/json"
      send_request(request, session: session, admin: admin)
    end

    def patch(path, body, session: nil, admin: false)
      request = Net::HTTP::Patch.new(URI.join(@endpoint, path))
      request.body = JSON.generate(body)
      request["Content-Type"] = "application/json"
      send_request(request, session: session, admin: admin)
    end

    def delete(path, session: nil, admin: false)
      request = Net::HTTP::Delete.new(URI.join(@endpoint, path))
      send_request(request, session: session, admin: admin)
    end

    def send_request(request, session: nil, admin: false)
      uri = request.uri
      request["X-Siberian-Session"] = session if session
      request["Authorization"] = "Bearer #{@admin_token}" if admin

      response = Net::HTTP.start(uri.hostname, uri.port, open_timeout: 3, read_timeout: 8) do |http|
        http.request(request)
      end

      return nil unless response.code.to_i.between?(200, 299)

      response.body.to_s.empty? ? {} : JSON.parse(response.body)
    rescue StandardError => e
      # A shell that will not render because Auth is slow is worse than one that
      # renders signed out. Callers treat nil as "could not answer".
      warn("auth call failed: #{e.message}")
      nil
    end
  end
end
