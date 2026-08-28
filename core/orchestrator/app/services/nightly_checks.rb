# frozen_string_literal: true

require "json"

# The result of the last unattended sweep, for the Overview.
#
# The smokes are the only thing covering the seams between Rails, nginx,
# Postgres, and the engine, and they used to run only when somebody remembered.
# They now run nightly on the box and leave this behind, so the answer to "does
# it still work" is on a page an operator already opens rather than in a log
# they would have to know about.
#
# Read from a file rather than fetched, because the sweep runs on the host,
# outside every container, and has no credential for anything here. A read only
# bind mount is the whole interface: the sweep writes, the Backoffice reads, and
# neither needs to know the other exists.
class NightlyChecks
  DEFAULT_PATH = "/var/lib/siberian/checks/latest.json"

  # After this long, a green result is not evidence of anything. Cron runs the
  # sweep daily, so anything approaching two days means it stopped running, and
  # a stale pass reported as a pass is worse than no report at all.
  STALE_AFTER = 40.hours

  Check = Struct.new(:name, :status, :seconds, :detail, keyword_init: true) do
    def ok? = status == "ok"
  end

  def initialize(path: ENV.fetch("SIBERIAN_CHECK_RESULTS", DEFAULT_PATH))
    @path = path
  end

  # Whether there is a result to show at all. False on a box where the sweep has
  # never run, which is not a failure and should not be drawn as one.
  def available? = data.present?

  def ran_at
    value = data["ran_at"]
    return nil if value.blank?

    Time.zone.parse(value)
  rescue ArgumentError
    nil
  end

  def stale?
    return false unless available?
    return true if ran_at.nil?

    ran_at < STALE_AFTER.ago
  end

  def checks
    Array(data["checks"]).map do |entry|
      Check.new(
        name: entry["name"], status: entry["status"],
        seconds: entry["seconds"].to_i, detail: entry["detail"]
      )
    end
  end

  def failures = checks.reject(&:ok?)
  def total = checks.length
  def passed = total - failures.length
  def duration_seconds = data["duration_seconds"].to_i

  # Green only when the sweep passed and recently. A page that says everything
  # is fine because of something that happened last week is the failure mode
  # this feature exists to remove, not one to reproduce in a card.
  def ok? = available? && !stale? && failures.empty?

  private

  def data
    @data ||= begin
      raw = File.read(@path)
      parsed = JSON.parse(raw)
      parsed.is_a?(Hash) ? parsed : {}
    rescue Errno::ENOENT, Errno::EACCES
      {}
    rescue JSON::ParserError => e
      # A truncated file is worth saying out loud rather than treating as
      # "never ran": the sweep writes atomically, so this means something else.
      Rails.logger.warn("could not parse #{@path}: #{e.message}")
      {}
    end
  end
end
