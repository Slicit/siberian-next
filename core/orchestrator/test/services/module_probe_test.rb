# frozen_string_literal: true

require "test_helper"

# What the probe accepts and what it refuses.
#
# The interesting cases are the ones that must pass. A probe that refuses
# anything unusual would be worse than none: it would make honest modules
# uninstallable, and the first response to that is to switch it off.
class ModuleProbeTest < ActiveSupport::TestCase
  setup do
    @installed = InstalledModule.new(name: "example-relay", uuid: SecureRandom.uuid)
  end

  def manifest(body)
    Siberian::Contracts::Manifest.parse(body)
  end

  # Answers whatever it is told to, without a network.
  class Answering < ModuleProbe
    def initialize(*args, answers:, **kwargs)
      super(*args, **kwargs)
      @answers = answers
      @asked = []
    end

    attr_reader :asked

    def get(path)
      @asked << path
      @answers.fetch(path, "404")
    end
  end

  def probe(answers, body)
    Answering.new(@installed, manifest(body), domain: "example.test",
                  answers: answers, attempts: 1, between: 0)
  end

  RELAY = <<~YAML
    schema_version: 1
    name: example-relay
    version: 1.0.0
    title: Relay
    containers:
      - service: web
        image: siberian/example-relay:1.0.0
        role: http
        internal_port: 8080
        health:
          path: /up
    routes:
      base: /example-relay
      entry: web
    capabilities:
      system:
        - id: relay.mail
          interface: mail.transport.v1
          endpoint: /internal/mail
          title: Relay
  YAML

  test "an endpoint that answers is accepted" do
    findings = probe({ "/internal/mail" => "200", "/up" => "200" }, RELAY).call

    assert findings.all?(&:ok?)
    assert_nil ModuleProbe.refusal(findings)
  end

  # The ordinary shape for a system capability. Refusing these would mean the
  # check could only be satisfied by a module that answers GET to everything.
  test "a POST-only endpoint is accepted, because 405 means it is there" do
    findings = probe({ "/internal/mail" => "405", "/up" => "200" }, RELAY).call

    assert_nil ModuleProbe.refusal(findings)
  end

  test "an endpoint that refuses an unauthenticated caller is still there" do
    %w[401 403].each do |status|
      findings = probe({ "/internal/mail" => status, "/up" => "200" }, RELAY).call

      assert_nil ModuleProbe.refusal(findings),
                 "#{status} is a module defending itself, not a module missing an endpoint"
    end
  end

  test "an endpoint that is not there is refused, and named" do
    findings = probe({ "/internal/mail" => "404", "/up" => "200" }, RELAY).call
    refusal = ModuleProbe.refusal(findings)

    assert refusal
    assert_includes refusal, "mail.transport.v1"
    assert_includes refusal, "/internal/mail"
  end

  test "a health path that is not there is refused too" do
    findings = probe({ "/internal/mail" => "200", "/up" => "404" }, RELAY).call

    assert_includes ModuleProbe.refusal(findings).to_s, "/up"
  end

  test "a module that never answers is refused" do
    findings = probe({ "/internal/mail" => "000", "/up" => "000" }, RELAY).call

    assert ModuleProbe.refusal(findings)
  end

  test "a module declaring nothing is asked nothing" do
    plain = <<~YAML
      schema_version: 1
      name: plain
      version: 1.0.0
      title: Plain
      containers:
        - service: web
          image: nginx:1.27-alpine
          role: http
          internal_port: 80
      routes:
        base: /plain
        entry: web
    YAML

    probed = probe({}, plain)
    findings = probed.call

    assert_empty findings
    assert_empty probed.asked, "a manifest that claims nothing has nothing to check"
    assert_nil ModuleProbe.refusal(findings)
  end

  test "every declared address is asked about, not just the first" do
    probed = probe({ "/internal/mail" => "200", "/up" => "200" }, RELAY)
    probed.call

    assert_equal %w[/internal/mail /up], probed.asked
  end
end
