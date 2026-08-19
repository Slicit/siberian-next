# frozen_string_literal: true

require_relative "test_helper"

class DockerDriverTest < Minitest::Test
  include Siberian

  def setup
    @http = TestSupport::FakeHTTP.new
    @driver = Engine::Drivers::Docker.new(http: @http)
  end

  def spec(overrides = {})
    Engine::ContainerSpec.new({
      name: "abc123-example-notes-web",
      image: "nginx:1.27-alpine",
      role: :http,
      aliases: ["example-notes"],
      env: { "RAILS_ENV" => "production" },
      internal_port: 80,
      labels: { "siberian.module_uuid" => "abc123" }
    }.merge(overrides))
  end

  def created_body
    call = @http.calls.find { |c| c[:path] == "/containers/create" }
    call.fetch(:body)
  end

  # Naming and identity --------------------------------------------------

  def test_create_names_the_container_from_the_spec
    @http.on(:get, "/images/nginx%3A1.27-alpine/json", TestSupport.response({}))
    @http.on(:post, "/containers/create", TestSupport.response({ "Id" => "deadbeef" }))

    id = @driver.create(spec, network: "siberian_mod_abc123")

    assert_equal "deadbeef", id
    create = @http.calls.find { |c| c[:path] == "/containers/create" }
    assert_equal({ "name" => "abc123-example-notes-web" }, create[:query])
  end

  def test_create_attaches_the_short_name_as_a_network_alias
    @http.on(:get, "/images/nginx%3A1.27-alpine/json", TestSupport.response({}))
    @http.on(:post, "/containers/create", TestSupport.response({ "Id" => "x" }))

    @driver.create(spec, network: "siberian_mod_abc123")

    endpoints = created_body.dig("NetworkingConfig", "EndpointsConfig")
    assert_equal ["example-notes"], endpoints.dig("siberian_mod_abc123", "Aliases")
  end

  # Isolation ------------------------------------------------------------

  def test_datastore_containers_never_expose_a_port
    @http.on(:get, "/images/redis%3A7-alpine/json", TestSupport.response({}))
    @http.on(:post, "/containers/create", TestSupport.response({ "Id" => "x" }))

    @driver.create(spec(image: "redis:7-alpine", role: :datastore, internal_port: 6379), network: "net")

    refute created_body.key?("ExposedPorts"), "a datastore must not expose ports"
    assert_equal false, created_body.dig("HostConfig", "PublishAllPorts")
  end

  def test_http_containers_expose_their_internal_port
    @http.on(:get, "/images/nginx%3A1.27-alpine/json", TestSupport.response({}))
    @http.on(:post, "/containers/create", TestSupport.response({ "Id" => "x" }))

    @driver.create(spec, network: "net")

    assert_equal({ "80/tcp" => {} }, created_body["ExposedPorts"])
  end

  def test_mounts_default_to_read_only
    @http.on(:get, "/images/nginx%3A1.27-alpine/json", TestSupport.response({}))
    @http.on(:post, "/containers/create", TestSupport.response({ "Id" => "x" }))

    mounts = [Engine::Mount.new(path: "/data", access: :read), Engine::Mount.new(path: "/rw", access: :write)]
    @driver.create(spec(mounts: mounts), network: "net")

    binds = created_body.dig("HostConfig", "Binds")
    assert_includes binds, "/data:/data:ro"
    assert_includes binds, "/rw:/rw:rw"
  end

  # Images ---------------------------------------------------------------

  def test_create_pulls_an_image_that_is_not_present
    @http.on(:get, "/images/nginx%3A1.27-alpine/json", Engine::UnixHTTP::Error.new(404, "{}"))
    @http.on(:post, "/containers/create", TestSupport.response({ "Id" => "x" }))

    @driver.create(spec, network: "net")

    pull = @http.calls.find { |c| c[:path] == "/images/create" }
    refute_nil pull, "a missing image should be pulled before create"
    assert_equal({ "fromImage" => "nginx", "tag" => "1.27-alpine" }, pull[:query])
  end

  def test_pull_uses_post_because_the_engine_streams_progress_from_it
    @driver.pull("nginx:1.27-alpine")

    pull = @http.calls.find { |c| c[:path] == "/images/create" }
    assert_equal "POST", pull[:verb], "a GET here returns a bare 404 that explains nothing"
  end

  def test_create_does_not_pull_an_image_already_present
    @http.on(:get, "/images/nginx%3A1.27-alpine/json", TestSupport.response({}))
    @http.on(:post, "/containers/create", TestSupport.response({ "Id" => "x" }))

    @driver.create(spec, network: "net")

    assert_nil @http.calls.find { |c| c[:path] == "/images/create" }
  end

  def test_image_reference_with_a_registry_port_is_not_mistaken_for_a_tag
    @http.on(:get, "/images/registry.local%3A5000%2Fapp/json", Engine::UnixHTTP::Error.new(404, "{}"))
    @http.on(:post, "/containers/create", TestSupport.response({ "Id" => "x" }))

    @driver.create(spec(image: "registry.local:5000/app"), network: "net")

    pull = @http.calls.find { |c| c[:path] == "/images/create" }
    assert_equal "registry.local:5000/app", pull[:query]["fromImage"]
    assert_equal "latest", pull[:query]["tag"]
  end

  # Lifecycle ------------------------------------------------------------

  def test_start_treats_already_running_as_success
    @http.on(:post, "/containers/x/start", Engine::UnixHTTP::Error.new(304, "{}"))

    assert @driver.start("x")
  end

  def test_remove_treats_a_missing_container_as_success
    @http.on(:delete, "/containers/gone", Engine::UnixHTTP::Error.new(404, "{}"))

    assert @driver.remove("gone")
  end

  def test_create_raises_already_exists_on_conflict
    @http.on(:get, "/images/nginx%3A1.27-alpine/json", TestSupport.response({}))
    @http.on(:post, "/containers/create", Engine::UnixHTTP::Error.new(409, "{}"))

    assert_raises(Engine::Driver::AlreadyExists) { @driver.create(spec, network: "net") }
  end

  def test_status_maps_engine_states_to_engine_neutral_symbols
    {
      "running" => :running,
      "exited" => :stopped,
      "created" => :stopped,
      "restarting" => :restarting,
      "dead" => :dead
    }.each do |docker_state, expected|
      http = TestSupport::FakeHTTP.new
      http.on(:get, "/containers/x/json", TestSupport.response({ "State" => { "Status" => docker_state } }))
      driver = Engine::Drivers::Docker.new(http: http)

      assert_equal expected, driver.status("x"), "#{docker_state} should map to #{expected}"
    end
  end

  def test_status_of_a_missing_container_is_absent
    @http.on(:get, "/containers/gone/json", Engine::UnixHTTP::Error.new(404, "{}"))

    assert_equal :absent, @driver.status("gone")
  end

  # Health ---------------------------------------------------------------

  def test_healthy_without_a_declared_healthcheck_means_running
    @http.on(:get, "/containers/x/json", TestSupport.response({ "State" => { "Status" => "running" } }))

    assert @driver.healthy?("x")
  end

  def test_healthy_with_a_declared_healthcheck_follows_the_engine
    @http.on(:get, "/containers/x/json",
             TestSupport.response({ "State" => { "Status" => "running", "Health" => { "Status" => "starting" } } }))

    refute @driver.healthy?("x")
  end

  def test_a_stopped_container_is_never_healthy
    @http.on(:get, "/containers/x/json", TestSupport.response({ "State" => { "Status" => "exited" } }))

    refute @driver.healthy?("x")
  end

  def test_declared_health_becomes_an_engine_healthcheck_in_nanoseconds
    @http.on(:get, "/images/nginx%3A1.27-alpine/json", TestSupport.response({}))
    @http.on(:post, "/containers/create", TestSupport.response({ "Id" => "x" }))

    @driver.create(spec(health: Engine::Health.new(path: "/up", interval_seconds: 15)), network: "net")

    check = created_body["Healthcheck"]
    assert_equal 15 * 1_000_000_000, check["Interval"]
    assert_includes check["Test"].last, "http://127.0.0.1:80/up"
  end

  # Discovery ------------------------------------------------------------

  def test_list_filters_by_label_and_returns_neutral_summaries
    @http.on(:get, "/containers/json", TestSupport.response([
      { "Id" => "a", "Names" => ["/abc-example-notes-web"], "Image" => "nginx", "State" => "running", "Labels" => {} }
    ]))

    result = @driver.list(labels: { "siberian.module_uuid" => "abc" })

    assert_equal "abc-example-notes-web", result.first[:name]
    call = @http.calls.last
    assert_equal '{"label":["siberian.module_uuid=abc"]}', call[:query]["filters"]
  end
end
