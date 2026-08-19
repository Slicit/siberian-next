# frozen_string_literal: true

require "net/http"
require "json"

# Reads and writes storage quotas, for the Backoffice.
#
# The Storage service owns the numbers; this only asks. Keeping the arithmetic
# on one side means the page and the enforcement can never disagree about how
# full something is.
class StorageClient
  def initialize(endpoint: ENV.fetch("SIBERIAN_STORAGE_URL", "http://storage:3000"),
                 token: ENV.fetch("SIBERIAN_ADMIN_TOKEN", "orchestrator_dev_only"))
    @endpoint = endpoint
    @token = token
  end

  def quotas = request(Net::HTTP::Get, "/admin/quotas")

  def update_defaults(attributes) = request(Net::HTTP::Patch, "/admin/quotas", attributes)

  def update_domain(domain, attributes)
    request(Net::HTTP::Patch, "/admin/quotas/domains/#{CGI.escape(domain)}", attributes)
  end

  def update_bucket(id, quota_mb)
    request(Net::HTTP::Patch, "/admin/quotas/buckets/#{id}", { quota_mb: quota_mb })
  end

  def recalculate = request(Net::HTTP::Post, "/admin/quotas/recalculate", {})

  def reachable? = !quotas.nil?

  private

  def request(verb, path, body = nil)
    uri = URI.join(@endpoint, path)
    message = verb.new(uri)
    message["Authorization"] = "Bearer #{@token}"

    if body
      message["Content-Type"] = "application/json"
      message.body = JSON.generate(body)
    end

    response = Net::HTTP.start(uri.hostname, uri.port, open_timeout: 3, read_timeout: 10) do |http|
      http.request(message)
    end

    return nil unless response.code.to_i.between?(200, 299)

    response.body.to_s.empty? ? {} : JSON.parse(response.body)
  rescue StandardError => e
    # A page that will not render because Storage is briefly slow is worse than
    # one that says so.
    Rails.logger.warn("storage call failed: #{e.message}")
    nil
  end
end
