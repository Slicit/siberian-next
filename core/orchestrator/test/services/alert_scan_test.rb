# frozen_string_literal: true

require "test_helper"

# What the scan reports, and more importantly what it does not.
#
# Most of these assert silence. An alerting system is judged by what it stays
# quiet about, because the failure mode is not missing an incident, it is
# sending so many that nobody reads the one that mattered.
class AlertScanTest < ActiveSupport::TestCase
  class Post
    attr_reader :sent

    def initialize = (@sent = [])

    def deliver(**message)
      @sent << message
      { "id" => @sent.length }
    end
  end

  class Mailer
    def initialize(report) = (@report = report)
    def queue(**) = @report
  end

  class Storage
    def initialize(report) = (@report = report)
    def quotas = @report
  end

  class Auth
    def initialize(directory) = (@directory = directory)
    def users = @directory
  end

  class Checks
    def initialize(available: true, stale: false, failures: [], ran_at: Time.current)
      @available = available
      @stale = stale
      @failures = failures
      @ran_at = ran_at
    end

    Failure = Struct.new(:name)

    def available? = @available
    def stale? = @stale
    def ran_at = @ran_at
    def failures = @failures.map { |name| Failure.new(name) }
    def total = 20
  end

  DIRECTORY = {
    "roles" => [
      { "name" => "operator", "permissions" => ["core.modules.read"] },
      { "name" => "member", "permissions" => %w[app.use module.*.use] }
    ],
    "users" => [
      { "email" => "boss@example.test", "active" => true, "roles" => ["operator"] },
      { "email" => "rider@example.test", "active" => true, "roles" => ["member"] },
      { "email" => "gone@example.test", "active" => false, "roles" => ["operator"] }
    ]
  }.freeze

  HEALTHY_QUEUE = {
    "counts" => { "sent" => 100, "dead" => 0 }, "stalled" => 0,
    "recent" => { "window_minutes" => 60, "sent" => 20, "dead" => 0 }
  }.freeze
  NO_DOMAINS = { "domains" => [] }.freeze

  def scan(mailer: HEALTHY_QUEUE, storage: NO_DOMAINS, checks: Checks.new, free: 20_000, post: Post.new)
    AlertScan.new(mailer: Mailer.new(mailer), post: post, auth: Auth.new(DIRECTORY),
                  storage: Storage.new(storage), checks: checks, free_megabytes: free)
  end

  test "a healthy system says nothing at all" do
    post = Post.new
    result = scan(post: post).call

    assert_empty result.opened
    assert_empty post.sent
    assert_equal 0, AlertCondition.count
  end

  test "a condition has to hold twice before anybody is emailed" do
    post = Post.new

    scan(free: 100, post: post).call
    assert_empty post.sent, "one bad reading during a deploy is not an incident"

    scan(free: 100, post: post).call
    assert_equal 1, post.sent.length
  end

  test "and is never emailed again while it stays true" do
    post = Post.new
    3.times { scan(free: 100, post: post).call }

    assert_equal 1, post.sent.length,
                 "the same true statement every quarter of an hour is how alerting becomes worthless"
  end

  test "only people who can act on it are told" do
    post = Post.new
    2.times { scan(free: 100, post: post).call }

    assert_equal ["boss@example.test"], post.sent.map { |m| m[:to] },
                 "a member cannot raise a quota or restart a worker"
  end

  test "several things going wrong at once is one email" do
    post = Post.new
    failing = Checks.new(failures: %w[smoke-mail smoke-cms])
    2.times { scan(free: 100, checks: failing, post: post).call }

    assert_equal 1, post.sent.length
    assert_match(/MB free/, post.sent.first[:text_body])
    assert_match(/smoke-mail/, post.sent.first[:text_body])
  end

  test "resolving is said once" do
    post = Post.new
    2.times { scan(free: 100, post: post).call }
    scan(free: 20_000, post: post).call
    scan(free: 20_000, post: post).call

    assert_equal 2, post.sent.length
    assert_match(/Resolved/, post.sent.last[:text_body])
  end

  # Each of these was considered for the list and left off.
  test "an ordinary queue with a few dead messages is not an alert" do
    post = Post.new
    queue = { "counts" => { "sent" => 1000, "dead" => 6 }, "stalled" => 0,
              "recent" => { "window_minutes" => 60, "sent" => 40, "dead" => 6 } }
    2.times { scan(mailer: queue, post: post).call }

    assert_empty post.sent,
                 "mail is getting through, so six that did not is six bad addresses"
  end

  test "but a transport refusing everything is" do
    post = Post.new
    queue = { "counts" => { "sent" => 2, "dead" => 30 }, "stalled" => 0,
              "recent" => { "window_minutes" => 60, "sent" => 0, "dead" => 9 } }
    2.times { scan(mailer: queue, post: post).call }

    assert_equal 1, post.sent.length
    assert_match(/refusing everything/, post.sent.first[:text_body])
  end

  test "a busy queue is not a stalled one" do
    post = Post.new
    # Messages in `sending` right now, none of them old enough to count.
    queue = { "counts" => { "sent" => 100, "dead" => 0 }, "stalled" => 0,
              "recent" => { "window_minutes" => 60, "sent" => 5, "dead" => 0 } }
    2.times { scan(mailer: queue, post: post).call }

    assert_empty post.sent
  end

  test "a worker that is not draining is" do
    post = Post.new
    queue = { "counts" => { "sent" => 100, "dead" => 0 }, "stalled" => 4,
              "recent" => { "window_minutes" => 60, "sent" => 5, "dead" => 0 } }
    2.times { scan(mailer: queue, post: post).call }

    assert_match(/not draining/, post.sent.first[:text_body])
  end

  test "a domain being used is not a domain running out" do
    post = Post.new
    storage = { "domains" => [{ "domain" => "a.test", "percent_used" => 71, "quota_mb" => 100 }] }
    2.times { scan(storage: storage, post: post).call }

    assert_empty post.sent
  end

  test "a domain nearly full is" do
    post = Post.new
    storage = { "domains" => [{ "domain" => "a.test", "percent_used" => 94, "quota_mb" => 100 }] }
    2.times { scan(storage: storage, post: post).call }

    assert_match(/a\.test is at 94%/, post.sent.first[:text_body])
  end

  test "a domain with no ceiling is a decision, not a problem" do
    post = Post.new
    storage = { "domains" => [{ "domain" => "a.test", "percent_used" => 99, "unlimited" => true }] }
    2.times { scan(storage: storage, post: post).call }

    assert_empty post.sent
  end

  # The one that catches the checker itself.
  test "a sweep that has stopped running is reported, not just a red one" do
    post = Post.new
    stopped = Checks.new(ran_at: 3.days.ago, stale: true)
    2.times { scan(checks: stopped, post: post).call }

    assert_match(/last ran/, post.sent.first[:text_body])
  end

  test "a red sweep is not reported when it is also stale, because stale is the bigger fact" do
    post = Post.new
    stopped = Checks.new(ran_at: 3.days.ago, stale: true, failures: %w[smoke-mail])
    2.times { scan(checks: stopped, post: post).call }

    refute_match(/nightly checks are failing/, post.sent.first[:text_body])
  end

  test "nobody to tell means nothing is sent and nothing crashes" do
    post = Post.new
    empty = AlertScan.new(mailer: Mailer.new(HEALTHY_QUEUE), post: post,
                          auth: Auth.new({ "roles" => [], "users" => [] }),
                          storage: Storage.new(NO_DOMAINS), checks: Checks.new,
                          free_megabytes: 100)

    2.times { empty.call }

    assert_empty post.sent
    assert_includes AlertCondition.firing.pluck(:key), "disk.low",
                    "it is still recorded, so the page shows it even when the email cannot go"
  end

  test "a service that cannot answer is not reported as a problem" do
    post = Post.new
    silent = AlertScan.new(mailer: Mailer.new(nil), post: post, auth: Auth.new(DIRECTORY),
                           storage: Storage.new(nil), checks: Checks.new, free_megabytes: 20_000)

    2.times { silent.call }

    assert_empty post.sent,
                 "the Mailer restarting must not be reported as the Mailer being broken"
  end

  # The one reality caught within a minute of this being switched on. The first
  # version compared lifetime dead against lifetime sent, fired on deaths from a
  # transport that had been fixed hours earlier, and would have gone on firing
  # forever: a ratio over all time never recovers.
  test "a transport that was broken and is working again goes quiet" do
    post = Post.new
    broken = { "counts" => { "sent" => 71, "dead" => 29 }, "stalled" => 0,
               "recent" => { "window_minutes" => 60, "sent" => 12, "dead" => 0 } }
    2.times { scan(mailer: broken, post: post).call }

    assert_empty post.sent,
                 "twenty nine deaths from last week is history, not an incident"
  end
end
