# frozen_string_literal: true

require "test_helper"

class SolidQueueTest < SpeedshopCloudwatchTest
  def setup
    super
    skip "Solid Queue is not installed; skipping Solid Queue tests" unless solid_queue_installed?
    require_relative "support/solid_queue_database"
    ActiveRecord::Base.connection.begin_transaction(joinable: false)
    require "speedshop/cloudwatch/solid_queue"
  end

  def teardown
    ActiveRecord::Base.connection.rollback_transaction if solid_queue_installed?
    super
  end

  def test_filters_queues_when_configured
    enqueue_test_jobs
    Speedshop::Cloudwatch.configure do |config|
      config.solid_queue_queues = ["critical", "default"]
    end

    queue_names = collect_solid_queue_queue_names
    assert_includes queue_names, "critical"
    assert_includes queue_names, "default"
    refute_includes queue_names, "low_priority"
  end

  def test_monitors_all_queues_by_default
    enqueue_test_jobs
    Speedshop::Cloudwatch.configure do |config|
      config.solid_queue_queues = nil
    end

    queue_names = collect_solid_queue_queue_names
    assert_includes queue_names, "critical"
    assert_includes queue_names, "default"
    assert_includes queue_names, "low_priority"
  end

  def test_collects_all_metrics_with_real_solid_queue_data
    enqueue_test_jobs
    claim(::SolidQueue::Job.find_by!(queue_name: "critical"), by: start_worker)
    Speedshop::Cloudwatch.configure do |config|
      config.metrics[:solid_queue] = [
        :QueueLatency, :QueueSize, :ClaimedJobs, :Processes, :Workers, :Capacity, :Utilization
      ]
    end

    collect_solid_queue_metrics

    metric_names = @test_client.find_metrics.map { |m| m[:metric_name] }
    assert_includes metric_names, "QueueLatency"
    assert_includes metric_names, "QueueSize"
    assert_includes metric_names, "ClaimedJobs"
    assert_includes metric_names, "Processes"
    assert_includes metric_names, "Workers"
    assert_includes metric_names, "Capacity"
    assert_includes metric_names, "Utilization"
  end

  def test_logs_error_when_collection_fails
    logger = TestDoubles::LoggerDouble.new

    Speedshop::Cloudwatch.configure do |config|
      config.logger = logger
    end

    ::SolidQueue::Process.stub(:where, ->(*) { raise "boom" }) do
      collector = Speedshop::Cloudwatch::SolidQueue.new
      collector.collect
    end

    assert logger.error_logged?("Failed to collect Solid Queue metrics"), "Expected error to be logged"
  end

  def test_ignores_stale_workers
    start_worker(pool_size: 3)
    start_worker(pool_size: 5, last_heartbeat_at: ::SolidQueue.process_alive_threshold.ago - 60)
    Speedshop::Cloudwatch.configure do |config|
      config.metrics[:solid_queue] = [:Processes, :Capacity]
    end

    collect_solid_queue_metrics

    assert_equal 1, @test_client.find_metrics(metric_name: "Processes").first[:value]
    assert_equal 3, @test_client.find_metrics(metric_name: "Capacity").first[:value]
  end

  private

  def solid_queue_installed?
    Gem.loaded_specs.key?("solid_queue")
  end

  def enqueue_test_jobs
    ::SolidQueue::Job.create!(queue_name: "critical", class_name: "TestJob")
    ::SolidQueue::Job.create!(queue_name: "default", class_name: "TestJob")
    ::SolidQueue::Job.create!(queue_name: "low_priority", class_name: "TestJob")
  end

  def start_worker(pool_size: 3, last_heartbeat_at: Time.now)
    ::SolidQueue::Process.create!(
      kind: "Worker",
      name: "worker-#{SecureRandom.hex(4)}",
      pid: Process.pid,
      last_heartbeat_at: last_heartbeat_at,
      metadata: {pool_size: pool_size}
    )
  end

  def claim(job, by:)
    job.ready_execution.destroy!
    ::SolidQueue::ClaimedExecution.create!(job: job, process: by)
  end

  def collect_solid_queue_metrics
    reporter = Speedshop::Cloudwatch.reporter
    collector = Speedshop::Cloudwatch::SolidQueue.new
    collector.collect
    reporter.start!
    reporter.flush_now!
  end

  def collect_solid_queue_queue_names
    collect_solid_queue_metrics

    metrics = @test_client.find_metrics
    queue_metrics = metrics.select do |m|
      m[:dimensions]&.any? { |d| d[:name] == "QueueName" }
    end
    queue_metrics.map { |m| m[:dimensions].find { |d| d[:name] == "QueueName" }[:value] }.uniq
  end
end
