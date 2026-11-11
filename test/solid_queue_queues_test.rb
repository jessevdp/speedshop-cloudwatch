# frozen_string_literal: true

require "test_helper"

class SolidQueueQueuesTest < SpeedshopCloudwatchTest
  def setup
    super
    skip "Solid Queue is not installed; skipping Solid Queue tests" unless solid_queue_installed?
    require_relative "support/solid_queue_database"
    ActiveRecord::Base.connection.begin_transaction(joinable: false)
    require "speedshop/cloudwatch/solid_queue_queues"
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

  def test_reports_queue_latency_per_queue
    enqueue_test_job("critical", created_at: 120.seconds.ago)
    enqueue_test_job("default", created_at: 240.seconds.ago)

    collect_solid_queue_metrics

    values = queue_metric_values("QueueLatency")
    assert_in_delta 120, values.fetch("critical"), 1
    assert_in_delta 240, values.fetch("default"), 1
  end

  def test_reports_queue_size_per_queue
    enqueue_test_jobs("critical" => 2, "default" => 1)
    enqueue_test_job("low_priority", scheduled_at: 1.hour.from_now)

    collect_solid_queue_metrics

    values = queue_metric_values("QueueSize")
    assert_equal 2, values.fetch("critical")
    assert_equal 1, values.fetch("default")
    assert_equal 0, values.fetch("low_priority")
  end

  def test_logs_error_when_collection_fails
    logger = TestDoubles::LoggerDouble.new
    Speedshop::Cloudwatch.configure { |config| config.logger = logger }

    ::SolidQueue::Queue.stub(:all, -> { raise "boom" }) do
      Speedshop::Cloudwatch::SolidQueueQueues.new.collect
    end

    assert logger.error_logged?("Failed to collect Solid Queue queue metrics"), "Expected error to be logged"
  end

  private

  def solid_queue_installed?
    Gem.loaded_specs.key?("solid_queue")
  end

  def enqueue_test_jobs(queue_counts = {"critical" => 1, "default" => 1, "low_priority" => 1})
    queue_counts.each do |queue_name, count|
      count.times { enqueue_test_job(queue_name) }
    end
  end

  def enqueue_test_job(queue_name, created_at: nil, scheduled_at: nil)
    job = ::SolidQueue::Job.create!(queue_name: queue_name, class_name: "TestJob", scheduled_at: scheduled_at)
    job.ready_execution.update!(created_at: created_at) if created_at
    job
  end

  def collect_solid_queue_metrics
    Speedshop::Cloudwatch.configure { |config| config.metrics[:solid_queue] = [:QueueLatency, :QueueSize] }
    reporter = Speedshop::Cloudwatch.reporter
    Speedshop::Cloudwatch::SolidQueueQueues.new.collect
    reporter.start!
    reporter.flush_now!
  end

  def queue_metric_values(metric_name)
    @test_client.find_metrics(metric_name: metric_name).each_with_object({}) do |metric, values|
      queue_name = metric[:dimensions].find { |dimension| dimension[:name] == "QueueName" }[:value]
      values[queue_name] = metric[:value]
    end
  end

  def collect_solid_queue_queue_names
    collect_solid_queue_metrics

    metrics = @test_client.find_metrics
    queue_metrics = metrics.select do |metric|
      metric[:dimensions]&.any? { |dimension| dimension[:name] == "QueueName" }
    end
    queue_metrics.map { |metric| metric[:dimensions].find { |dimension| dimension[:name] == "QueueName" }[:value] }.uniq
  end
end
