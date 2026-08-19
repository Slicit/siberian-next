# frozen_string_literal: true

require "test_helper"

class InterfaceRegistryTest < ActiveSupport::TestCase
  setup { @registry = InterfaceRegistry.new }

  def install_relay(priority: 50, exclusive: false, status: "running")
    installed = InstalledModule.create!(
      uuid: SecureRandom.hex(6), name: "example-relay", version: "0.1.0",
      title: "Relay", status: status, origin: "example-relay", entry_service: "web"
    )
    installed.capabilities.create!(
      kind: "system", capability_id: "example_relay.mail.transport",
      interface: "mail.transport.v1", endpoint: "/internal/mail",
      title: "Relay", priority: priority, exclusive: exclusive
    )
    installed
  end

  test "with no module installed the core answers for itself" do
    resolved = @registry.resolve("mail.transport.v1")

    assert resolved.built_in?
    assert_equal "http://mailer:3000/internal/mail", resolved.url
  end

  test "a module implementation outranks the core service" do
    install_relay

    resolved = @registry.resolve("mail.transport.v1")

    refute resolved.built_in?
    assert_equal "example-relay", resolved.provider
    assert_equal "http://example-relay/internal/mail", resolved.url
  end

  test "a module can deliberately sit behind the core by asking for it" do
    install_relay(priority: Capability::CORE_PRIORITY + 1)

    assert @registry.resolve("mail.transport.v1").built_in?
  end

  test "a module that is not live is not routed to" do
    install_relay(status: "failed")

    assert @registry.resolve("mail.transport.v1").built_in?,
           "a failed module must not keep receiving the core's mail"
  end

  test "an interface nothing implements resolves to nothing" do
    assert_nil @registry.resolve("cache.store.v1"),
               "no implementation is a real answer: the feature is unavailable"
  end

  test "the core's built-in interfaces are always listed" do
    assert_includes @registry.known_interfaces, "mail.transport.v1"
    assert_includes @registry.known_interfaces, "auth.provider.v1"
  end

  test "implementations are ordered best first" do
    install_relay(priority: 50)
    second = InstalledModule.create!(
      uuid: SecureRandom.hex(6), name: "other-relay", version: "1.0.0",
      title: "Other", status: "running", origin: "other-relay", entry_service: "web"
    )
    second.capabilities.create!(
      kind: "system", capability_id: "other_relay.mail.transport",
      interface: "mail.transport.v1", endpoint: "/internal/mail", title: "Other", priority: 10
    )

    order = @registry.implementations("mail.transport.v1").map(&:provider)

    assert_equal %w[other-relay example-relay core], order
  end
end
