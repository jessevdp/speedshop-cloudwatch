# frozen_string_literal: true

require "speedshop/cloudwatch/observations"

module Speedshop
  module Cloudwatch
    class SolidQueueProcesses
      class << self
        attr_accessor :supervisor
      end

      def collect
        supervisor = self.class.supervisor
        return unless supervisor&.pid == ::Process.pid

        Observations::SolidQueue.process_observations(supervisor.process_id).each do |observation|
          metric_mapper.report(
            metric: observation[:metric],
            value: observation[:value],
            dimensions: observation[:dimensions] || {},
            integration: :solid_queue
          )
        end
      rescue => e
        Speedshop::Cloudwatch.log_error("Failed to collect Solid Queue process metrics: #{e.message}", e)
      end

      private

      def metric_mapper
        Speedshop::Cloudwatch.metric_mapper
      end
    end
  end
end
