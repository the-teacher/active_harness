require "test_helper"
require "tmpdir"
require "fileutils"

begin
  require "rails"
  require "rails/generators"
  require "generators/active_harness/install/install_generator"
  GENERATORS_AVAILABLE = true
rescue LoadError
  GENERATORS_AVAILABLE = false
end

class InstallGeneratorTest < Minitest::Test
  def setup
    skip "railties is not installed" unless GENERATORS_AVAILABLE
    @root = Dir.mktmpdir
    FileUtils.mkdir_p("#{@root}/config")
    File.write("#{@root}/config/routes.rb", "Rails.application.routes.draw do\nend\n")
  end

  def teardown
    FileUtils.remove_entry(@root) if @root
  end

  def run_install
    capture_io { ActiveHarness::Generators::InstallGenerator.start([], destination_root: @root) }
  end

  def files
    Dir["#{@root}/**/*"].select { |f| File.file?(f) }.sort.map { |f| [f.sub("#{@root}/", ""), File.read(f)] }.to_h
  end

  def test_clean_app_gets_an_example_in_every_directory
    run_install
    %w[concerns requests prompts tribunals pipelines memory agents tools goals].each do |dir|
      assert Dir["#{@root}/app/ai/#{dir}/*.rb"].any?, "app/ai/#{dir} has no example"
    end
    assert File.exist?("#{@root}/app/ai/concerns/tracing_log.rb")
    assert_match(/include AgentTracing/, File.read("#{@root}/app/ai/agents/files_agent.rb"))
  end

  def test_rerun_changes_nothing_and_does_not_duplicate_routes
    run_install
    before = files
    run_install
    assert_equal before, files
    assert_equal 1, File.read("#{@root}/config/routes.rb").scan('"ai/files_agent"').size
  end

  def test_existing_files_are_never_touched
    FileUtils.mkdir_p("#{@root}/app/ai/requests")
    FileUtils.mkdir_p("#{@root}/app/ai/concerns")
    File.write("#{@root}/app/ai/requests/support_request.rb", "# MINE\n")
    File.write("#{@root}/app/ai/concerns/request_tracing.rb", "# MY TRACING\n")
    File.write("#{@root}/config/routes.rb", "Rails.application.routes.draw do\n  post \"ai/pipeline\", to: \"mine#pipeline\"\nend\n")

    run_install

    assert_equal "# MINE\n", File.read("#{@root}/app/ai/requests/support_request.rb")
    assert_equal "# MY TRACING\n", File.read("#{@root}/app/ai/concerns/request_tracing.rb")
    assert File.exist?("#{@root}/app/ai/requests/files_request.rb"), "missing dependencies of the examples are still added"
    routes = File.read("#{@root}/config/routes.rb")
    assert_equal 1, routes.scan('"ai/pipeline"').size
    assert_includes routes, "mine#pipeline"
  end
end
