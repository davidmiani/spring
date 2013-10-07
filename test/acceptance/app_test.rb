# encoding: utf-8
require 'helper'
require 'io/wait'
require "timeout"
require "spring/sid"
require "spring/env"

class AppTest < ActiveSupport::TestCase
  DEFAULT_SPEEDUP = 0.8
  DEFAULT_TIMEOUT = ENV['CI'] ? 30 : 10

  def rails_version
    ENV['RAILS_VERSION'] || '~> 4.0.0'
  end

  def rails_3?
    rails_version.split(" ").last =~ /^3/
  end

  def app_root
    Pathname.new("#{TEST_ROOT}/apps/rails-#{rails_version.scan(/\d/)[0..1].join("-")}")
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

  def log_file
    @log_file ||= File.open("/tmp/spring.log", "w+")
  end

  def env
    @env ||= {
      "GEM_HOME"   => gem_home.to_s,
      "GEM_PATH"   => "",
      "HOME"       => user_home.to_s,
      "RAILS_ENV"  => nil,
      "RACK_ENV"   => nil,
      "SPRING_LOG" => log_file.path
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

    if pid = spring_env.pid
      @server_pid = pid
      lines = `ps -A -o ppid= -o pid= | egrep '^\\s*#{@server_pid}'`.lines
      @application_pids = lines.map { |l| l.split.last.to_i }
    end

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
      log:    read_stream(log_file)
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

  def alive?(pid)
    Process.kill 0, pid
    true
  rescue Errno::ESRCH
    false
  end

  def await_reload
    raise "no pid" if @application_pids.nil? || @application_pids.empty?

    Timeout.timeout(DEFAULT_TIMEOUT) do
      sleep 0.1 while @application_pids.any? { |p| alive?(p) }
    end
  end

  def debug(artifacts)
    artifacts = artifacts.dup
    artifacts.delete :status
    dump_streams(artifacts.delete(:command), artifacts)
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
    if ENV['CI']
      yield
    else
      @times = []
      yield
      assert (@times.last / @times.first) < ratio, "#{@times.last} was not less than #{ratio} of #{@times.first}"
      @times = nil
    end
  end

  def spring_test_command
    "#{spring} testunit #{@test}"
  end

  def generate_app
    Bundler.with_clean_env do
      system "(gem list rails --installed --version '#{rails_version}' || " \
             "gem install rails --version '#{rails_version}') > /dev/null"

      # Have to shell out otherwise bundler prevents us finding the gem
      version = `ruby -e 'puts Gem::Specification.find_by_name("rails", "#{rails_version}").version'`.chomp

      system "rails _#{version}_ new #{app_root} --skip-bundle --skip-javascript --skip-sprockets > /dev/null"

      FileUtils.mkdir_p(gem_home)
      FileUtils.mkdir_p(user_home)
      FileUtils.rm_rf("#{app_root}/test/performance/")
    end
  end

  def install
    generate_app unless app_root.exist?

    system "gem build spring.gemspec 2>/dev/null 1>/dev/null"
    app_run "gem install ../../../spring-#{Spring::VERSION}.gem"
    app_run "(gem list bundler | grep bundler) || gem install bundler", timeout: nil
    app_run "bundle check || bundle update", timeout: nil

    unless File.exist?(@controller)
      app_run "bundle exec rails g scaffold post title:string"
    end

    app_run "bundle exec rake db:migrate db:test:clone"
    @@installed = true
  end

  @@installed = false

  setup do
    @test       = "#{app_root}/test/#{rails_3? ? 'functional' : 'controllers'}/posts_controller_test.rb"
    @controller = "#{app_root}/app/controllers/posts_controller.rb"

    install unless @@installed

    @test_contents       = File.read(@test)
    @controller_contents = File.read(@controller)
  end

  teardown do
    app_run "#{spring} stop"
    File.write(@test, @test_contents)
    File.write(@controller, @controller_contents)
    FileUtils.rm_f("#{app_root}/config/spring.rb")
  end

  test "changing the Gemfile restarts the server" do
    begin
      gemfile = app_root.join("Gemfile")
      gemfile_contents = gemfile.read

      puts "Gemfile: #{File.mtime(gemfile)}"
      puts "Gemfile.lock: #{File.mtime("#{gemfile}.lock")}"
      assert_success %(#{spring} rails runner 'require "sqlite3"') 

      File.write(gemfile, gemfile_contents.sub(%{gem 'sqlite3'}, %{# gem 'sqlite3'}))
      app_run "bundle check"

      puts "Gemfile: #{File.mtime(gemfile)}"
      puts "Gemfile.lock: #{File.mtime("#{gemfile}.lock")}"

      await_reload
      assert_failure %(#{spring} rails runner 'require "sqlite3"'), stderr: "sqlite3"
    ensure
      File.write(gemfile, gemfile_contents)
      assert_success "bundle check"
    end
  end
end
