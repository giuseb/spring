# encoding: utf-8
require 'helper'
require 'io/wait'
require "timeout"
require "spring/sid"
require "spring/env"

class AppTest < ActiveSupport::TestCase
  # Runtimes on the CI tend to be a bit more volatile, so make
  # the ratio more permissive
  DEFAULT_SPEEDUP = ENV['CI'] ? 0.8 : 0.6
  DEFAULT_TIMEOUT = ENV['CI'] ? 30 : 10

  TTY = "/tmp/spring_test_tty"

  def app_root
    Pathname.new("#{TEST_ROOT}/apps/rails-3-2")
  end

  def gem_home
    app_root.join "vendor/gems/#{RUBY_VERSION}"
  end

  def user_home
    app_root.join "user_home"
  end

  def spring
    gem_home.join "bin/spring"
  end

  def spring_env
    @spring_env ||= Spring::Env.new(app_root)
  end

  def stdout
    @stdout ||= IO.pipe
  end

  def stderr
    @stderr ||= IO.pipe
  end

  def tty
    @tty ||= File.open(TTY, "w+")
  end

  def env
    @env ||= {
      "GEM_HOME"   => gem_home.to_s,
      "GEM_PATH"   => "",
      "SPRING_TTY" => tty.path,
      "HOME"       => user_home.to_s
    }
  end

  def app_run(command, opts = {})
    start_time = Time.now

    Bundler.with_clean_env do
      Process.spawn(
        env,
        command.to_s,
        out:   stdout.last,
        err:   stderr.last,
        in:    :close,
        chdir: app_root.to_s,
      )
    end

    _, status = Timeout.timeout(opts.fetch(:timeout, DEFAULT_TIMEOUT)) { Process.wait2 }

    output = read_streams
    puts dump_streams(command, output) if ENV["SPRING_DEBUG"]

    @times << (Time.now - start_time) if @times

    output.merge(status: status, command: command)
  rescue Timeout::Error => e
    raise e, "Output:\n\n#{dump_streams(command, read_streams)}"
  end

  def read_streams
    {
      stdout: read_stream(stdout.first),
      stderr: read_stream(stderr.first),
      tty:    read_stream(tty)
    }
  end

  def read_stream(stream)
    output = ""
    while IO.select([stream], [], [], 0.5) && !stream.eof?
      output << stream.readpartial(10240)
    end
    output
  end

  def dump_streams(command, streams)
    output = "$ #{command}\n"

    streams.each do |name, stream|
      unless stream.chomp.empty?
        output << "--- #{name} ---\n"
        output << "#{stream.chomp}\n"
      end
    end

    output << "\n"
    output
  end

  def await_reload
    sleep 0.4
  end

  def debug(artifacts)
    dump_streams(
      artifacts[:command],
      stdout: artifacts[:stdout],
      stderr: artifacts[:stderr],
      tty:    artifacts[:tty]
    )
  end

  def assert_output(artifacts, expected)
    expected.each do |stream, output|
      assert artifacts[stream].include?(output),
             "expected #{stream} to include '#{output}'.\n\n#{debug(artifacts)}"
    end
  end

  def assert_success(command, expected_output = nil)
    artifacts = app_run(command)
    assert artifacts[:status].success?, "expected successful exit status\n\n#{debug(artifacts)}"
    assert_output artifacts, expected_output if expected_output
  end

  def assert_failure(command, expected_output = nil)
    artifacts = app_run(command)
    assert !artifacts[:status].success?, "expected unsuccessful exit status\n\n#{debug(artifacts)}"
    assert_output artifacts, expected_output if expected_output
  end

  def assert_speedup(ratio = DEFAULT_SPEEDUP)
    @times = []
    yield
    assert (@times.last / @times.first) < ratio, "#{@times.last} was not less than #{ratio} of #{@times.first}"
    @times = nil
  end

  def spring_test_command
    "#{spring} testunit #{@test}"
  end

  @@installed = false

  setup do
    @test                = "#{app_root}/test/functional/posts_controller_test.rb"
    @test_contents       = File.read(@test)
    @spec                = "#{app_root}/spec/dummy_spec.rb"
    @spec_contents       = File.read(@spec)
    @controller          = "#{app_root}/app/controllers/posts_controller.rb"
    @controller_contents = File.read(@controller)

    unless @@installed
      FileUtils.mkdir_p(gem_home)
      system "gem build spring.gemspec 2>/dev/null 1>/dev/null"
      app_run "gem install ../../../spring-#{Spring::VERSION}.gem"
      app_run "(gem list bundler | grep bundler) || gem install bundler #{'--pre' if RUBY_VERSION >= "2.0"}", timeout: nil
      app_run "bundle check || bundle update", timeout: nil
      app_run "bundle exec rake db:migrate db:test:clone"
      @@installed = true
    end

    FileUtils.rm_rf "#{app_root}/bin"
  end

  teardown do
    app_run "#{spring} stop"
    File.write(@test,       @test_contents)
    File.write(@spec,       @spec_contents)
    File.write(@controller, @controller_contents)
  end

  test "basic" do
    assert_speedup do
      2.times { app_run spring_test_command }
    end
  end

  test "help message when called without arguments" do
    assert_success spring, stdout: 'Usage: spring COMMAND [ARGS]'
  end

  test "test changes are picked up" do
    assert_speedup do
      assert_success spring_test_command, stdout: "0 failures"

      File.write(@test, @test_contents.sub("get :index", "raise 'omg'"))
      assert_failure spring_test_command, stdout: "RuntimeError: omg"
    end
  end

  test "code changes are picked up" do
    assert_speedup do
      assert_success spring_test_command, stdout: "0 failures"

      File.write(@controller, @controller_contents.sub("@posts = Post.all", "raise 'omg'"))
      assert_failure spring_test_command, stdout: "RuntimeError: omg"
    end
  end

  test "code changes in pre-referenced app files are picked up" do
    begin
      initializer = "#{app_root}/config/initializers/load_posts_controller.rb"
      File.write(initializer, "PostsController\n")

      assert_speedup do
        assert_success spring_test_command, stdout: "0 failures"

        File.write(@controller, @controller_contents.sub("@posts = Post.all", "raise 'omg'"))
        assert_failure spring_test_command, stdout: "RuntimeError: omg"
      end
    ensure
      FileUtils.rm_f(initializer)
    end
  end

  def assert_app_reloaded
    application = "#{app_root}/config/application.rb"
    application_contents = File.read(application)

    assert_success spring_test_command

    File.write(application, application_contents + <<-CODE)
      class Foo
        def self.omg
          raise "omg"
        end
      end
    CODE
    File.write(@test, @test_contents.sub("get :index", "Foo.omg"))

    await_reload

    assert_speedup do
      2.times { assert_failure spring_test_command, stdout: "RuntimeError: omg" }
    end
  ensure
    File.write(application, application_contents)
  end

  test "app gets reloaded when preloaded files change (polling watcher)" do
    assert_success "#{spring} rails runner 'puts Spring.watcher.class'", stdout: "Polling"
    assert_app_reloaded
  end

  test "app gets reloaded when preloaded files change (listen watcher)" do
    begin
      gemfile = app_root.join("Gemfile")
      gemfile_contents = gemfile.read
      File.write(gemfile, gemfile_contents.sub(%{# gem 'listen'}, %{gem 'listen'}))

      config_path = "#{app_root}/config/spring.rb"
      config_contents = File.read(config_path)
      File.write(config_path,config_contents + "\nSpring.watch_method = :listen")

      app_run "bundle install", timeout: nil

      assert_success "#{spring} rails runner 'puts Spring.watcher.class'", stdout: "Listen"
      assert_app_reloaded
    ensure
      File.write(config_path,config_contents)
      File.write(gemfile, gemfile_contents)
      assert_success "bundle check"
    end
  end

  test "app recovers when a boot-level error is introduced" do
    begin
      application = "#{app_root}/config/application.rb"
      application_contents = File.read(application)

      assert_success spring_test_command

      File.write(application, application_contents + "\nomg")
      await_reload

      assert_failure spring_test_command

      File.write(application, application_contents)
      await_reload

      assert_success spring_test_command
    ensure
      File.write(application, application_contents)
    end
  end

  test "stop command kills server" do
    app_run spring_test_command
    assert spring_env.server_running?, "The server should be running but it isn't"

    assert_success "#{spring} stop"
    assert !spring_env.server_running?, "The server should not be running but it is"
  end

  test "custom commands" do
    assert_success "#{spring} custom", stdout: "omg"
  end

  test "binstubs" do
    app_run "#{spring} binstub rake"
    app_run "#{spring} binstub rails"
    assert_success "bin/spring help"
    assert_success "bin/rake -T", stdout: "rake db:migrate"
    assert_success "bin/rails runner 'puts %(omg)'", stdout: "omg"
  end

  test "after fork callback" do
    begin
      config_path = "#{app_root}/config/spring.rb"
      config_contents = File.read(config_path)

      File.write(config_path, config_contents + "\nSpring.after_fork { puts '!callback!' }")
      assert_success "#{spring} rails runner 'puts 2'", stdout: "!callback!\n2"
    ensure
      File.write(config_path, config_contents)
    end
  end

  test "global config file evaluated" do
    begin
      config_path = "#{user_home}/.spring.rb"
      config_contents = File.read(config_path)

      File.write(config_path, config_contents + "\nSpring.after_fork { puts '!global_config!' }")
      assert_success "#{spring} rails runner 'puts 2'", stdout: "!global_config!\n2"
    ensure
      File.write(config_path, config_contents)
    end
  end

  test "missing config/application.rb" do
    begin
      FileUtils.mv app_root.join("config/application.rb"), app_root.join("config/application.rb.bak")

      assert_output(
        app_run("#{spring} rake -T"),
        tty: "unable to find your config/application.rb"
      )
    ensure
      FileUtils.mv app_root.join("config/application.rb.bak"), app_root.join("config/application.rb")
    end
  end

  test "piping" do
    assert_success "#{spring} rake -T | grep db", stdout: "rake db:migrate"
  end

  test "status" do
    assert_success "#{spring} status", stdout: "Spring is not running"
    app_run "#{spring} rails runner ''"
    assert_success "#{spring} status", stdout: "Spring is running"
  end

  test "runner command sets Rails environment from command-line options" do
    assert_success "#{spring} rails runner -e production 'puts Rails.env'", stdout: "production"
    assert_success "#{spring} rails runner --environment=production 'puts Rails.env'", stdout: "production"
  end

  test "forcing rails env via environment variable" do
    env['RAILS_ENV'] = 'production'
    assert_success "#{spring} rake -p 'Rails.env'", stdout: "production"
  end

  test "exit code for failing specs" do
    assert_success "#{spring} rspec"
    File.write(@spec, @spec_contents.sub("true.should be_true", "false.should be_true"))
    assert_failure "#{spring} rspec"
  end

  test "changing the Gemfile restarts the server" do
    begin
      gemfile = app_root.join("Gemfile")
      gemfile_contents = gemfile.read

      assert_success %(#{spring} rails runner 'require "rspec"')

      File.write(gemfile, gemfile_contents.sub(%{gem 'rspec'}, %{# gem 'rspec'}))
      app_run "bundle check"

      await_reload
      assert_failure %(#{spring} rails runner 'require "rspec"'), stderr: "cannot load such file -- rspec"
    ensure
      File.write(gemfile, gemfile_contents)
      assert_success "bundle check"
    end
  end
end
