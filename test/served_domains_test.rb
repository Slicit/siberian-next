# frozen_string_literal: true

require_relative "test_helper"
require "lib/served_domains"
require "tmpdir"

# Which domains an installation serves, as every service needs to know it.
#
# The tests that matter are the refusals and the fallback. This decides whether
# Rails answers a request at all, so a bug here is either a domain that stops
# working or a Host header nobody vetted.
class ServedDomainsTest < Minitest::Test
  def setup = reset
  def teardown = reset

  def reset
    ENV.delete("SIBERIAN_DOMAINS_FILE")
    ENV.delete("SIBERIAN_DOMAINS")
    ENV.delete("SIBERIAN_DOMAIN")
    Siberian::ServedDomains.reset!
  end

  def with_file(*domains)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "domains.txt")
      Siberian::ServedDomains.write!(domains, to: path)
      ENV["SIBERIAN_DOMAINS_FILE"] = path
      Siberian::ServedDomains.reset!
      yield path
    end
  end

  def test_serves_a_domain_from_the_file
    with_file("first.test", "second.test") do
      assert Siberian::ServedDomains.serves?("first.test")
      assert Siberian::ServedDomains.serves?("second.test")
    end
  end

  # Every origin in this system is a subdomain of a served domain, so a list of
  # exact hosts would have to grow on every module install.
  def test_serves_subdomains_of_a_served_domain
    with_file("first.test") do
      assert Siberian::ServedDomains.serves?("core.first.test")
      assert Siberian::ServedDomains.serves?("s3.first.test")
      assert Siberian::ServedDomains.serves?("tasks.apps.first.test")
    end
  end

  def test_refuses_a_domain_it_does_not_serve
    with_file("first.test") do
      refute Siberian::ServedDomains.serves?("evil.test")
      refute Siberian::ServedDomains.serves?("")
      refute Siberian::ServedDomains.serves?(nil)
    end
  end

  # The reason `end_with?` alone is not enough: a suffix match would serve
  # anybody who registered a domain ending in the same letters.
  def test_a_domain_that_merely_ends_with_a_served_one_is_refused
    with_file("first.test") do
      refute Siberian::ServedDomains.serves?("notfirst.test"),
             "a suffix match would hand the shell to whoever registers it"
      refute Siberian::ServedDomains.serves?("first.test.evil.test")
    end
  end

  def test_the_port_is_ignored
    with_file("first.test") do
      assert Siberian::ServedDomains.serves?("first.test:443")
      assert Siberian::ServedDomains.serves?("core.first.test:3000")
    end
  end

  def test_matching_is_case_insensitive_and_ignores_a_trailing_dot
    with_file("first.test") do
      assert Siberian::ServedDomains.serves?("FIRST.TEST")
      assert Siberian::ServedDomains.serves?("Core.First.Test")
      # A fully qualified name with the root label spelled out.
      assert Siberian::ServedDomains.serves?("first.test.")
    end
  end

  # A deployment that has never reconciled has no file, and must behave exactly
  # as it did before this existed.
  def test_falls_back_to_the_environment_when_there_is_no_file
    ENV["SIBERIAN_DOMAINS_FILE"] = "/nonexistent/domains.txt"
    ENV["SIBERIAN_DOMAINS"] = "from-env.test, second-env.test"
    Siberian::ServedDomains.reset!

    assert Siberian::ServedDomains.serves?("from-env.test")
    assert Siberian::ServedDomains.serves?("core.second-env.test")
  end

  def test_the_environment_and_the_file_are_both_honoured
    with_file("from-file.test") do
      ENV["SIBERIAN_DOMAIN"] = "from-env.test"
      Siberian::ServedDomains.reset!

      assert Siberian::ServedDomains.serves?("from-file.test")
      assert Siberian::ServedDomains.serves?("from-env.test"),
             "a domain in the environment must not stop working because a file appeared"
    end
  end

  def test_writing_is_atomic_and_leaves_no_temporary_behind
    with_file("first.test") do |path|
      Siberian::ServedDomains.write!(%w[a.test b.test], to: path)

      assert_equal %W[a.test\n b.test\n], File.readlines(path)
      assert_empty Dir.glob("#{path}.*"), "a temporary file left behind would be read as a domain list"
    end
  end

  def test_it_normalises_what_it_writes
    with_file("first.test") do |path|
      written = Siberian::ServedDomains.write!(["  Mixed.Case.test ", "", "dup.test", "dup.test"], to: path)

      assert_equal %w[mixed.case.test dup.test], written
    end
  end
end
