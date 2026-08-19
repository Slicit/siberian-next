# frozen_string_literal: true

require "test_helper"

class InstalledModuleTest < ActiveSupport::TestCase
  def build_module(**overrides)
    InstalledModule.create!({
      uuid: SecureRandom.hex(6),
      name: "demo-tasks",
      version: "1.0.0",
      title: "Demo Tasks",
      status: "running",
      origin: "demo-tasks",
      entry_service: "web"
    }.merge(overrides))
  end

  test "the origin is a subdomain of the domain being served" do
    installed = build_module

    assert_equal "demo-tasks.apps.example.test", installed.origin_for("example.test")
  end

  test "a module with no origin falls back to its name" do
    installed = build_module(origin: nil)

    assert_equal "demo-tasks.apps.example.test", installed.origin_for("example.test")
  end

  test "status is derived from the containers, not asserted" do
    installed = build_module

    assert_equal "stopped", installed.derived_status, "no containers means nothing is running"

    installed.module_containers.create!(service: "web", name: "a-demo-tasks-web", image: "nginx",
                                        role: "http", state: "running")
    assert_equal "running", installed.reload.derived_status

    installed.module_containers.create!(service: "worker", name: "a-demo-tasks-worker", image: "ruby",
                                        role: "worker", state: "stopped")
    assert_equal "degraded", installed.reload.derived_status

    installed.module_containers.last.update!(state: "dead")
    assert_equal "failed", installed.reload.derived_status
  end

  test "two modules cannot share a name" do
    build_module

    assert_raises(ActiveRecord::RecordInvalid) { build_module(uuid: SecureRandom.hex(6)) }
  end
end
