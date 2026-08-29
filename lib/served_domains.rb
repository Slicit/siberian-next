# frozen_string_literal: true

module Siberian
  # Which domains this installation serves, as the applications need to know it.
  #
  # Rails refuses a Host header it was not told about, and the list of domains
  # lives in the Orchestrator's database, which no other service can read. So the
  # Orchestrator publishes it as a file on the volume it already uses to publish
  # the Router's configuration, and everything else reads it.
  #
  # A file rather than an API call because this is consulted on the way into
  # every request, including the requests that would be made to ask. A service
  # that had to call the Orchestrator to find out whether it may answer could
  # not answer the Orchestrator.
  #
  # The environment is still read and still wins nothing: `SIBERIAN_DOMAINS` and
  # `SIBERIAN_DOMAIN` are merged in, so a deployment that has never run a
  # reconcile behaves exactly as it did before this existed, and one that has
  # picks up a new domain without a restart.
  module ServedDomains
    DEFAULT_PATH = "/var/lib/siberian/router/domains.txt"

    # How long a read is trusted before the file is looked at again. Short
    # enough that adding a domain takes effect while somebody is still watching
    # the page, long enough that it is not a stat per request.
    TTL_SECONDS = 10

    class << self
      # Every domain this installation serves, lowercased and unique.
      def all
        cached = @cache
        return cached[:domains] if cached && cached[:expires_at] > monotonic

        domains = (from_file + from_env).map { |d| d.to_s.strip.downcase }.reject(&:empty?).uniq
        @cache = { domains: domains.freeze, expires_at: monotonic + TTL_SECONDS }
        domains
      end

      # Whether `host` is one of them, or a subdomain of one.
      #
      # Subdomains count because that is how every origin in this system is
      # shaped: `core.<domain>`, `s3.<domain>`, `<module>.apps.<domain>`. A list
      # of exact hosts would have to grow every time a module is installed.
      def serves?(host)
        candidate = host.to_s.split(":").first.to_s.strip.downcase.sub(/\.\z/, "")
        return false if candidate.empty?

        all.any? do |domain|
          candidate == domain || candidate.end_with?(".#{domain}")
        end
      end

      def path = ENV["SIBERIAN_DOMAINS_FILE"] || DEFAULT_PATH

      # Written by the Orchestrator. Used by everything, including the
      # Orchestrator, so there is one answer rather than one per service.
      def write!(domains, to: path)
        require "fileutils"
        FileUtils.mkdir_p(File.dirname(to))
        body = Array(domains).map { |d| d.to_s.strip.downcase }.reject(&:empty?).uniq

        # Whole file, atomically, so a service reading mid-write sees the
        # previous list rather than half of the next one.
        temporary = "#{to}.#{Process.pid}.tmp"
        File.write(temporary, body.join("\n") + "\n")
        File.rename(temporary, to)

        reset!
        body
      end

      def reset! = @cache = nil

      private

      def from_file
        File.readlines(path, chomp: true)
      rescue SystemCallError
        # No file yet, or not mounted here. The environment still answers, which
        # is what every service did before this existed.
        []
      end

      def from_env
        list = ENV["SIBERIAN_DOMAINS"].to_s.split(",")
        list << ENV["SIBERIAN_DOMAIN"].to_s
        list
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
