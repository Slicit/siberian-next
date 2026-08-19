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
      delivered = drain
      # Only sleep when there was nothing to do. A busy queue should not wait
      # five seconds between messages.
      sleep(@interval) if delivered.zero? && @running
    end

    @logger.info("mail worker stopped")
  end

  # Works until the queue has nothing due, then returns how many it handled.
  def drain(limit: 50)
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
