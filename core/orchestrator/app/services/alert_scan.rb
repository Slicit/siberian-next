# frozen_string_literal: true

# What is wrong right now, and who needs telling.
#
# Every condition here had to earn its place against three questions, because an
# alert that fails any of them is the reason people stop reading alerts.
#
#   Can somebody act on it? If the answer is "look at it and shrug", it is a
#   statistic and belongs on a page.
#
#   Will it fix itself? A message a worker abandoned is reclaimed within minutes
#   by the worker itself, so it is not an alert. A worker that is not running at
#   all never fixes anything, so it is.
#
#   Is it actually bad? A failed build is ordinary. One dead message is a bad
#   address. Neither is worth waking up for, and putting them here would bury
#   the one that is.
#
# Deliberately absent, and each of these was considered:
#
#   Build failures. They fail for ordinary reasons, several times a day, and the
#   queue page already says so.
#   A single dead message. That is one wrong address, not a broken system.
#   Container restarts. The engine restarts things; that is its job.
#   Anything that resolved before the next scan. See AlertCondition: a condition
#   has to hold twice before a word is said.
class AlertScan
  # A domain this close to its ceiling will hit it, and the person who can raise
  # it is not the person who will notice. Below this, nothing is said: a domain
  # at seventy percent is a domain being used.
  STORAGE_PERCENT = 90

  # Free space on the box itself. Housekeeping runs at half past four and prunes
  # hard below eight gigabytes; this is lower, because being told about
  # something housekeeping is about to fix is noise.
  DISK_FLOOR_MB = 3_000

  # A sweep older than this has not merely failed, it has stopped, which is the
  # failure that hides every other one. Longer than a day, so a nightly run that
  # is a few hours late is not an incident.
  SWEEP_STALE_HOURS = 36

  # A module that has been unhealthy this long is not restarting, it is broken.
  UNHEALTHY_MINUTES = 15

  def initialize(mailer: Siberian::MailerClient.new(logger: Rails.logger),
                 post: Siberian::CoreMailClient.new(logger: Rails.logger),
                 auth: Siberian::AuthClient.new,
                 storage: StorageClient.new,
                 checks: NightlyChecks.new,
                 free_megabytes: nil)
    @mailer = mailer
    @post = post
    @auth = auth
    @storage = storage
    @checks = checks
    @free_megabytes = free_megabytes
  end

  Result = Struct.new(:opened, :closed, :firing, :notified, keyword_init: true)

  def call(notify: true)
    opened = []
    closed = []

    conditions.each do |key, detail|
      case AlertCondition.record(key, detail)
      when :opened then opened << AlertCondition.find_by(key: key)
      when :closed then closed << key
      end
    end

    notified = false
    notified = announce(opened, closed) if notify && (opened.any? || closed.any?)

    Result.new(opened: opened.map(&:key), closed: closed,
               firing: AlertCondition.firing.ordered.pluck(:key), notified: notified)
  end

  private

  # Every condition, evaluated. A nil detail means fine.
  #
  # One hash rather than a list of objects on purpose: the set is small, the
  # whole point is being able to read it in one screen and ask whether each line
  # deserves to be there.
  def conditions
    checks = {}

    checks["sweep.red"] = sweep_red
    checks["sweep.stopped"] = sweep_stopped
    checks["disk.low"] = disk_low
    checks["mail.worker.stalled"] = mail_stalled
    checks["mail.transport.failing"] = mail_transport_failing

    storage_conditions.each { |key, detail| checks[key] = detail }
    module_conditions.each { |key, detail| checks[key] = detail }

    checks
  end

  def sweep_red
    return nil unless @checks.available?
    return nil if @checks.stale?
    return nil if @checks.failures.empty?

    "#{@checks.failures.length} of #{@checks.total} nightly checks are failing: " \
      "#{@checks.failures.map(&:name).join(', ')}"
  end

  # The one that catches the checker. A sweep that has stopped running looks
  # exactly like a sweep that is passing, from every page that reads its result.
  def sweep_stopped
    return "the nightly sweep has never run here" unless @checks.available?
    return nil unless @checks.ran_at && @checks.ran_at < SWEEP_STALE_HOURS.hours.ago

    "the nightly sweep last ran #{((Time.current - @checks.ran_at) / 3600).round} hours ago"
  end

  # Free space on the box, which nothing in a container can see: `df` inside one
  # reports the container's filesystem. Whoever invokes the scan from the host
  # passes it in, and nil means nobody could say, so nothing is claimed.
  def disk_low
    return nil if @free_megabytes.nil?
    return nil if @free_megabytes >= DISK_FLOOR_MB

    "#{@free_megabytes} MB free on the box, below the #{DISK_FLOOR_MB} MB floor"
  end

  def mail_stalled
    report = @mailer.queue(limit: 1)
    return nil if report.nil?

    # The Mailer's own count of messages sitting in `sending` longer than a
    # delivery can take. A plain count of `sending` would fire on every busy
    # queue, which is the queue working.
    stalled = report["stalled"].to_i
    return nil if stalled.zero?

    # The worker reclaims its own at the top of every drain, so anything still
    # here is a worker that is not running, and that is the sentence worth
    # sending: it names what to restart.
    "#{stalled} message(s) stuck sending; the mail worker is not draining the queue"
  end
  # "Is mail failing now", which is a different question from "has mail ever
  # failed". The first version asked the second, fired on twenty five deaths
  # from a transport that had been fixed hours earlier, and would have kept
  # firing forever, which is precisely how an alert becomes something people
  # filter.
  #
  # Recent deaths with no recent successes. One message getting through is
  # enough to say the transport works, and clears this by itself.
  def mail_transport_failing
    report = @mailer.queue(limit: 1)
    return nil if report.nil?

    recent = report["recent"] || {}
    dead = recent["dead"].to_i
    sent = recent["sent"].to_i

    return nil if dead < 3
    return nil if sent.positive?

    "#{dead} messages died in the last #{recent['window_minutes'] || 60} minutes and none were " \
      "delivered; the transport is refusing everything"
  end
  def storage_conditions
    report = @storage.quotas
    return {} if report.nil?

    Array(report["domains"]).each_with_object({}) do |domain, found|
      # `unlimited` is a decision an operator made, not a thing to warn about.
      next if domain["unlimited"]

      percent = domain["percent_used"].to_i
      next if percent < STORAGE_PERCENT

      found["storage.#{domain['domain']}"] =
        "#{domain['domain']} is at #{percent}% of its #{domain['quota_mb']} MB storage allowance"
    end
  end
  def module_conditions
    InstalledModule.all.each_with_object({}) do |installed, found|
      next if installed.status == "running"
      # A module installed minutes ago is allowed to be starting.
      next if installed.updated_at > UNHEALTHY_MINUTES.minutes.ago

      found["module.#{installed.name}"] =
        "#{installed.name} has been #{installed.status} for over #{UNHEALTHY_MINUTES} minutes"
    end
  end

  # One message, however many conditions changed. Somebody who has just had four
  # things go wrong needs one email listing four things, not four emails.
  def announce(opened, closed)
    recipients = operators
    return false if recipients.empty?

    body = +""

    if opened.any?
      body << "Started:\n\n"
      opened.each { |condition| body << "  #{condition.detail}\n" }
      body << "\n"
    end

    if closed.any?
      # Worth sending. An alert with no end is one somebody has to go and check
      # by hand to find out whether it is still true.
      body << "Resolved:\n\n"
      closed.each { |key| body << "  #{key}\n" }
      body << "\n"
    end

    body << "The Backoffice has the detail: https://core.#{primary_domain}/\n"

    subject = if opened.any?
                "#{opened.length} thing(s) need attention on #{primary_domain}"
              else
                "Resolved on #{primary_domain}"
              end

    recipients.each do |address|
      @post.deliver(
        domain: primary_domain, to: address, subject: subject, text_body: body,
        # Keyed on what changed, so two scans racing cannot send it twice.
        idempotency_key: "alert-#{Digest::SHA256.hexdigest(subject + body)[0, 16]}-#{address}"
      )
    end

    true
  end

  # Whoever can act on it, asked rather than configured: a list of addresses in
  # a settings file is a thing that goes stale the first time somebody leaves.
  #
  # An operator is somebody holding a role that grants anything in `core.`, which
  # is derived from the catalogue rather than from the role's name, because roles
  # are editable and "operator" is only a word.
  def operators
    directory = @auth.users
    return [] if directory.nil?

    operator_roles = Array(directory["roles"]).select do |role|
      Array(role["permissions"]).any? { |p| p == "*" || p.to_s.start_with?("core.") }
    end.map { |role| role["name"] }

    Array(directory["users"])
      .select { |user| user["active"] && (Array(user["roles"]) & operator_roles).any? }
      .map { |user| user["email"] }
      .compact
      .uniq
  end
  def primary_domain
    @primary_domain ||= (Domain.find_by(primary: true) || Domain.ordered.first)&.hostname ||
                        ENV.fetch("SIBERIAN_DOMAIN", "siberian.test")
  end
end
