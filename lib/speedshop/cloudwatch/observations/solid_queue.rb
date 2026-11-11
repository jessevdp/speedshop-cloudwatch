# frozen_string_literal: true

module Speedshop
  module Cloudwatch
    module Observations
      module SolidQueue
        module_function

        def queue_observations(solid_queue_queues)
          queues_to_monitor(solid_queue_queues).flat_map do |queue|
            [
              {metric: :QueueLatency, value: queue.latency, dimensions: {QueueName: queue.name}},
              {metric: :QueueSize, value: queue.size, dimensions: {QueueName: queue.name}}
            ]
          end
        end

        def queues_to_monitor(solid_queue_queues)
          all_queues = ::SolidQueue::Queue.all
          return all_queues if solid_queue_queues.nil? || solid_queue_queues.empty?

          all_queues.select { |queue| solid_queue_queues.include?(queue.name) }
        end
      end
    end
  end
end
