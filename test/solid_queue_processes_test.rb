# frozen_string_literal: true

require "test_helper"

class SolidQueueProcessesTest < SpeedshopCloudwatchTest
  def setup
    super
    skip "Solid Queue is not installed; skipping Solid Queue tests" unless solid_queue_installed?
    require_relative "support/solid_queue_database"
    ActiveRecord::Base.connection.begin_transaction(joinable: false)
    require "speedshop/cloudwatch/solid_queue_processes"
  end

  def teardown
    Speedshop::Cloudwatch::SolidQueueProcesses.supervisor = nil
    ActiveRecord::Base.connection.rollback_transaction if solid_queue_installed?
    super
  end

  def test_reports_processes
    supervisor = start_supervisor
    2.times { start_worker(supervisor_id: supervisor.process_id) }

    collect_solid_queue_metrics(supervisor)

    assert_equal 2, @test_client.find_metrics(metric_name: "Processes").first[:value]
  end

  def test_reports_workers
    supervisor = start_supervisor
    first_worker = start_worker(supervisor_id: supervisor.process_id)
    second_worker = start_worker(supervisor_id: supervisor.process_id)
    create_and_assign_jobs(first_worker, 1)
    create_and_assign_jobs(second_worker, 2)

    collect_solid_queue_metrics(supervisor)

    assert_equal 3, @test_client.find_metrics(metric_name: "Workers").first[:value]
  end

  def test_reports_capacity
    supervisor = start_supervisor
    start_worker(supervisor_id: supervisor.process_id, pool_size: 2)
    start_worker(supervisor_id: supervisor.process_id, pool_size: 4)

    collect_solid_queue_metrics(supervisor)

    assert_equal 6, @test_client.find_metrics(metric_name: "Capacity").first[:value]
  end

  def test_reports_utilization
    supervisor = start_supervisor
    busy_worker = start_worker(supervisor_id: supervisor.process_id, pool_size: 2)
    start_worker(supervisor_id: supervisor.process_id, pool_size: 4)
    create_and_assign_jobs(busy_worker, 1)

    collect_solid_queue_metrics(supervisor)

    assert_in_delta 25.0, @test_client.find_metrics(metric_name: "Utilization").first[:value], 0.01
  end

  def test_counts_only_its_own_supervisors_workers
    supervisor = start_supervisor
    other_supervisor = start_supervisor
    start_worker(supervisor_id: supervisor.process_id, pool_size: 3)
    start_worker(supervisor_id: other_supervisor.process_id, pool_size: 5)

    collect_solid_queue_metrics(supervisor)

    assert_equal 1, @test_client.find_metrics(metric_name: "Processes").first[:value]
    assert_equal 3, @test_client.find_metrics(metric_name: "Capacity").first[:value]
  end

  def test_ignores_stale_workers
    supervisor = start_supervisor
    start_worker(supervisor_id: supervisor.process_id, pool_size: 3)
    start_worker(
      supervisor_id: supervisor.process_id,
      pool_size: 5,
      last_heartbeat_at: ::SolidQueue.process_alive_threshold.ago - 60
    )

    collect_solid_queue_metrics(supervisor)

    assert_equal 1, @test_client.find_metrics(metric_name: "Processes").first[:value]
    assert_equal 3, @test_client.find_metrics(metric_name: "Capacity").first[:value]
  end

  def test_publishes_nothing_without_live_workers
    supervisor = start_supervisor

    collect_solid_queue_metrics(supervisor)

    assert_empty @test_client.find_metrics
  end

  def test_skips_collecting_in_a_forked_process
    supervisor = start_supervisor
    start_worker(supervisor_id: supervisor.process_id)

    ::Process.stub(:pid, supervisor.pid + 1) do
      collect_solid_queue_metrics(supervisor)
    end

    assert_empty @test_client.find_metrics
  end

  def test_logs_error_when_collection_fails
    supervisor = start_supervisor
    logger = TestDoubles::LoggerDouble.new
    Speedshop::Cloudwatch.configure { |config| config.logger = logger }

    ::SolidQueue::Process.stub(:where, ->(*) { raise "boom" }) do
      collect_solid_queue_metrics(supervisor)
    end

    assert logger.error_logged?("Failed to collect Solid Queue process metrics"), "Expected error to be logged"
  end

  private

  def solid_queue_installed?
    Gem.loaded_specs.key?("solid_queue")
  end

  def start_supervisor
    row = ::SolidQueue::Process.create!(
      kind: "Supervisor",
      name: "supervisor-#{SecureRandom.hex(4)}",
      pid: ::Process.pid,
      last_heartbeat_at: Time.now
    )
    Struct.new(:pid, :process_id).new(row.pid, row.id)
  end

  def start_worker(supervisor_id:, pool_size: 3, last_heartbeat_at: Time.now)
    ::SolidQueue::Process.create!(
      kind: "Worker",
      name: "worker-#{SecureRandom.hex(4)}",
      pid: ::Process.pid,
      supervisor_id: supervisor_id,
      last_heartbeat_at: last_heartbeat_at,
      metadata: {pool_size: pool_size}
    )
  end

  def create_and_assign_jobs(worker, count)
    count.times do
      ::SolidQueue::Job.create!(queue_name: "default", class_name: "TestJob")
    end
    ::SolidQueue::ReadyExecution.claim(["*"], count, worker.id)
  end

  def collect_solid_queue_metrics(supervisor)
    Speedshop::Cloudwatch.configure do |config|
      config.metrics[:solid_queue] = [:Processes, :Workers, :Capacity, :Utilization]
    end
    Speedshop::Cloudwatch::SolidQueueProcesses.supervisor = supervisor
    Speedshop::Cloudwatch::SolidQueueProcesses.new.collect

    reporter = Speedshop::Cloudwatch.reporter
    reporter.start!
    reporter.flush_now!
  end
end
