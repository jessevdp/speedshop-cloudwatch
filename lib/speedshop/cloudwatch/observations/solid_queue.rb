# frozen_string_literal: true

module Speedshop
  module Cloudwatch
    module Observations
      module SolidQueue
        module_function

        def collect(solid_queue_queues: Config.instance.solid_queue_queues)
          processes = live_worker_processes

          process_observations(processes) + utilization_observations(processes) + queue_observations(solid_queue_queues)
        end

        def process_observations(processes)
          {
            Processes: processes.size,
            Workers: processes.sum { |process| process.claimed_executions.size }
          }.map do |metric, value|
            {metric: metric, value: value}
          end
        end

        def utilization_observations(processes)
          observations = [{metric: :Capacity, value: processes.sum { |process| process.metadata["pool_size"] }}]

          utilization = avg_utilization(processes) * 100.0
          observations << {metric: :Utilization, value: utilization} unless utilization.nan?
          observations
        end

        def queue_observations(solid_queue_queues)
          claimed_by_queue = ::SolidQueue::ClaimedExecution.joins(:job).group(:queue_name).count

          queues_to_monitor(solid_queue_queues).flat_map do |queue|
            [
              {metric: :QueueLatency, value: queue.latency, dimensions: {QueueName: queue.name}},
              {metric: :QueueSize, value: queue.size, dimensions: {QueueName: queue.name}},
              {metric: :ClaimedJobs, value: claimed_by_queue.fetch(queue.name, 0), dimensions: {QueueName: queue.name}}
            ]
          end
        end

        def queues_to_monitor(solid_queue_queues)
          all_queues = ::SolidQueue::Queue.all
          return all_queues if solid_queue_queues.nil? || solid_queue_queues.empty?

          all_queues.select { |queue| solid_queue_queues.include?(queue.name) }
        end

        def live_worker_processes
          ::SolidQueue::Process
            .where(kind: "Worker", last_heartbeat_at: ::SolidQueue.process_alive_threshold.ago..)
            .includes(:claimed_executions)
            .to_a
        end

        def avg_utilization(processes)
          utils = processes.map { |process| process.claimed_executions.size / process.metadata["pool_size"].to_f }.reject(&:nan?)
          utils.sum / utils.size.to_f
        end
      end
    end
  end
end
