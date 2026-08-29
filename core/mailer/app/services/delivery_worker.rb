# frozen_string_literal: true

# Claims due messages and tries to deliver them.
#
# Runs as its own container rather than a thread inside the web process, so a
# stuck delivery cannot take the API down with it and so the two can be scaled
# and restarted separately.
class DeliveryWorker
  DEFAULT_INTERVAL = 5

  def initialize(interval: ENV.fetch("MAILER_POLL_INTERVAL", DEFAULT_INTERVAL).to_f, logger: Rails.logger)
    @interval = interval
    @logger = logger
    @running = true
  end

  def run
    trap_signals
    @logger.info("mail worker started, polling every #{@interval}s")

    while @running
      begin
        delivered = drain
        # Only sleep when there was nothing to do. A busy queue should not wait
        # five seconds between messages.
        sleep(@interval) if delivered.zero? && @running
      rescue StandardError => e
        # The database being briefly unreachable, or a migration running, should
        # not end the worker. Exiting looks like a crash loop to whoever is
        # watching and stops the queue moving for as long as it takes somebody
        # to notice; waiting and trying again is what a queue is for.
        @logger.error("worker loop error: #{e.class}: #{e.message}")
        sleep(@interval)
      end
    end

    @logger.info("mail worker stopped")
  end

  # Works until the queue has nothing due, then returns how many it handled.
  def drain(limit: 50)
    # Before claiming anything: whatever the last worker was holding when it
    # died is nobody's otherwise, and a restarted worker is exactly the thing
    # that should pick it up. Doing it here rather than in a nightly sweep
    # means the recovery happens in minutes rather than the next morning.
    released = Message.release_stale!
    @logger.warn("released #{released} message(s) a worker had stopped sending") if released.positive?

    handled = 0

    limit.times do
      message = Message.claim_next!
      break if message.nil?

      deliver(message)
      handled += 1
    end

    handled
  end

  def deliver(message)
    transport = Transport.resolve
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    result = transport.deliver(message)
    duration = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round

    if result.delivered?
      message.record_success!(transport: transport.name, duration_ms: duration, detail: result.detail)
      @logger.info("delivered ##{message.id} via #{transport.name} in #{duration}ms")
    else
      message.record_failure!(
        transport: transport.name, error: result.detail,
        permanent: result.permanent?, duration_ms: duration
      )
      @logger.warn("failed ##{message.id} via #{transport.name}: #{result.detail} " \
                   "(attempt #{message.attempts}/#{message.max_attempts}, now #{message.state})")
    end

    message
  rescue StandardError => e
    # A message left in `sending` is a message nothing will ever pick up again,
    # so an unexpected error still has to land it somewhere a retry can find it.
    @logger.error("worker error on ##{message.id}: #{e.class}: #{e.message}")
    message.record_failure!(transport: "unknown", error: "#{e.class}: #{e.message}")
    message
  end

  private

  def trap_signals
    %w[INT TERM].each do |signal|
      Signal.trap(signal) do
        @running = false
      end
    end
  end
end
