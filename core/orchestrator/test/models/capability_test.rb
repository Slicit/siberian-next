# frozen_string_literal: true

require "test_helper"

class CapabilityTest < ActiveSupport::TestCase
  setup do
    @installed = InstalledModule.create!(
      uuid: "abc123", name: "demo-tasks", version: "1.0.0", title: "Demo",
      status: "running", origin: "demo-tasks", entry_service: "web"
    )
  end

  test "a feature capability needs somewhere to appear" do
    capability = @installed.capabilities.build(kind: "feature", capability_id: "demo.task.viewer", title: "Tasks")

    refute capability.valid?
    assert_includes capability.errors.attribute_names, :area
    assert_includes capability.errors.attribute_names, :path
  end

  test "a system capability needs an interface and an endpoint" do
    capability = @installed.capabilities.build(kind: "system", capability_id: "demo.mail.transport", title: "T")

    refute capability.valid?
    assert_includes capability.errors.attribute_names, :interface
    assert_includes capability.errors.attribute_names, :endpoint
  end

  test "a feature capability is reachable from a browser at the module origin" do
    capability = @installed.capabilities.create!(
      kind: "feature", capability_id: "demo.task.viewer", area: "sidebar.entities",
      title: "Tasks", path: "/tasks"
    )

    assert_equal "https://demo-tasks.apps.example.test/tasks", capability.url_for("example.test")
    assert_raises(RuntimeError) { capability.internal_url }
  end

  test "a system capability is reached by the core over the internal network" do
    capability = @installed.capabilities.create!(
      kind: "system", capability_id: "demo.mail.transport", interface: "mail.transport.v1",
      title: "Transport", endpoint: "/internal/mail"
    )

    assert_equal "http://demo-tasks/internal/mail", capability.internal_url
    assert_raises(RuntimeError) { capability.url_for("example.test") }
  end

  test "capability ids are unique across both kinds" do
    @installed.capabilities.create!(kind: "feature", capability_id: "demo.thing.viewer",
                                    area: "a", title: "A", path: "/a")

    duplicate = @installed.capabilities.build(kind: "system", capability_id: "demo.thing.viewer",
                                              interface: "x.v1", endpoint: "/x", title: "X")

    refute duplicate.valid?
  end

  test "an area lists only feature capabilities" do
    @installed.capabilities.create!(kind: "feature", capability_id: "demo.task.viewer",
                                    area: "sidebar.entities", title: "Tasks", path: "/tasks")
    @installed.capabilities.create!(kind: "system", capability_id: "demo.mail.transport",
                                    interface: "mail.transport.v1", endpoint: "/m", title: "T")

    assert_equal ["demo.task.viewer"], Capability.in_area("sidebar.entities").pluck(:capability_id)
  end
end
