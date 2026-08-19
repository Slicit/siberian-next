# frozen_string_literal: true

require "net/http"
require "json"

# Tells the Storage and Database services about a module, and collects the
# tokens they issue.
#
# Runs before containers are created, because those tokens are injected into the
# containers as environment. A module that has to fetch its own credentials from
# somewhere it has not yet been told about cannot start.
class ServiceRegistrar
  class Error < StandardError; end

  Registration = Struct.new(:storage_token, :database_token, :mail_token, :mobile_token, keyword_init: true)

  def initialize(storage_url: ENV.fetch("SIBERIAN_STORAGE_URL", "http://storage:3000"),
                 database_url: ENV.fetch("SIBERIAN_DATABASE_URL_SERVICE", "http://database:3000"),
                 mailer_url: ENV.fetch("SIBERIAN_MAILER_URL", "http://mailer:3000"),
                 mobile_url: ENV.fetch("SIBERIAN_MOBILE_URL", "http://mobile:3000"),
                 admin_token: ENV.fetch("SIBERIAN_ADMIN_TOKEN", "orchestrator_dev_only"))
    @storage_url = storage_url
    @database_url = database_url
    @mailer_url = mailer_url
    @mobile_url = mobile_url
    @admin_token = admin_token
  end

  def register(installed_module, manifest)
    Registration.new(
      storage_token: register_storage(installed_module, manifest),
      database_token: register_database(installed_module, manifest),
      mail_token: register_mailer(installed_module, manifest),
      mobile_token: register_mobile(installed_module, manifest)
    )
  end

  # Per (module, domain). Buckets and databases are per domain because that is
  # where isolation lives; the module and its containers are not.
  def provision(installed_module, manifest, domain)
    provisions = []
    provisions << provision_storage(installed_module, domain) if manifest.storage_spaces.any?

    manifest.owned_database_grants.each do |grant|
      provisions << provision_database(installed_module, domain, grant["name"])
    end

    provisions
  end

  # The grants an operator approved, handed to the service that will enforce
  # them. Sent with the reason, so the audit trail six months from now says why
  # somebody was allowed to read a table rather than only that they were.
  def approve_table_grants(installed_module, manifest)
    manifest.cross_database_grants.map do |grant|
      post(@database_url, "/admin/modules/#{installed_module.name}/table_grants", {
        target_database: grant["target"],
        tables: Array(grant["tables"]),
        access: grant["access"] || "read",
        reason: grant["reason"]
      })
      "#{grant['target']}: #{Array(grant['tables']).join(', ')}"
    end
  end

  def revoke(installed_module)
    %W[#{@storage_url}/admin/modules/#{installed_module.name}
       #{@database_url}/admin/modules/#{installed_module.name}
       #{@mailer_url}/admin/modules/#{installed_module.name}].each do |url|
      delete(url)
    rescue StandardError => e
      Rails.logger.warn("could not revoke #{url}: #{e.message}")
    end
  end

  private

  def register_storage(installed_module, manifest)
    return nil if manifest.storage_spaces.empty?

    body = post(@storage_url, "/admin/modules", {
      module_name: installed_module.name,
      module_uuid: installed_module.uuid,
      spaces: manifest.storage_spaces,
      quota_mb: manifest.storage_grant["quota_mb"] || 512,
      tmp_ttl_hours: manifest.storage_grant["tmp_ttl_hours"] || 168
    })
    body["token"]
  end

  # A module that asked to send mail gets a queue token. A module that did not
  # gets nothing, and its calls to the Mailer are refused by the token check
  # rather than by anything remembering the manifest.
  def register_mailer(installed_module, manifest)
    return nil unless manifest.mail_grant && manifest.mail_grant["send"]

    body = post(@mailer_url, "/admin/modules", {
      module_name: installed_module.name,
      module_uuid: installed_module.uuid,
      daily_limit: manifest.mail_grant["daily_limit"]
    })
    body["token"]
  end

  # What this module contributes to a phone app, and what it says it needs to
  # do it. Registered for every module, not only the ones shipping native code:
  # a module with no native block still appears in the app as the WebView it
  # would have had anyway, and the app has to know it exists to show it.
  def register_mobile(installed_module, manifest)
    body = post(@mobile_url, "/admin/modules", {
      module_name: installed_module.name,
      module_uuid: installed_module.uuid,
      native_entry: manifest.native_entry,
      fallback: manifest.native_fallback,
      base_route: manifest.base_route,
      origin: manifest.origin,
      screens: manifest.native_screens,
      # Sent as asked for. Whether any of it is on is decided per app, by an
      # operator: an operator setting caps a manifest, never the reverse.
      requires: manifest.required_native_capabilities
    })
    body["token"]
  rescue Error
    # A module still installs when the Mobile service is down. Phone apps are
    # not a reason a module cannot be installed, and the next build reads this
    # from the manifest again.
    nil
  end

  def register_database(installed_module, manifest)
    return nil if manifest.database_grants.empty?

    body = post(@database_url, "/admin/modules", {
      module_name: installed_module.name,
      module_uuid: installed_module.uuid
    })
    body["token"]
  end

  def provision_storage(installed_module, domain)
    body = post(@storage_url, "/admin/modules/#{installed_module.name}/buckets", { domain: domain.hostname })
    { kind: "storage", identifier: body["bucket"] }
  end

  def provision_database(installed_module, domain, logical_name)
    body = post(@database_url, "/admin/modules/#{installed_module.name}/databases",
                { domain: domain.hostname, logical_name: logical_name })
    { kind: "database", identifier: body["database"] }
  end

  def post(base, path, payload)
    uri = URI.join(base, path)
    request = Net::HTTP::Post.new(uri)
    request["Authorization"] = "Bearer #{@admin_token}"
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(payload)

    response = Net::HTTP.start(uri.hostname, uri.port, open_timeout: 5, read_timeout: 30) do |http|
      http.request(request)
    end

    unless response.code.to_i.between?(200, 299)
      raise Error, "#{uri} returned #{response.code}: #{response.body.to_s[0, 300]}"
    end

    response.body.to_s.empty? ? {} : JSON.parse(response.body)
  rescue Errno::ECONNREFUSED, Net::OpenTimeout => e
    raise Error, "#{base} unreachable: #{e.message}"
  end

  def delete(url)
    uri = URI.parse(url)
    request = Net::HTTP::Delete.new(uri)
    request["Authorization"] = "Bearer #{@admin_token}"
    Net::HTTP.start(uri.hostname, uri.port, open_timeout: 3, read_timeout: 10) { |http| http.request(request) }
  end
end
