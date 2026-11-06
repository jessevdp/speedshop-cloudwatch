# frozen_string_literal: true

require "speedshop/cloudwatch/observations"

module Speedshop
  module Cloudwatch
    class SolidQueue
      def collect
        Observations::SolidQueue.collect.each do |observation|
          metric_mapper.report(
            metric: observation[:metric],
            value: observation[:value],
            dimensions: observation[:dimensions] || {},
            integration: :solid_queue
          )
        end
      rescue => e
        Speedshop::Cloudwatch.log_error("Failed to collect Solid Queue metrics: #{e.message}", e)
      end

      class << self
        def setup_lifecycle_hooks
          ::SolidQueue.on_dispatcher_start do
            Speedshop::Cloudwatch.configure { |c| c.collectors << :solid_queue }
            Speedshop::Cloudwatch.start!
          end

          ::SolidQueue.on_dispatcher_stop do
            Speedshop::Cloudwatch.stop!
          end

          ::SolidQueue.on_dispatcher_exit do
            Speedshop::Cloudwatch.stop!
          end
        end
      end

      private

      def metric_mapper
        Speedshop::Cloudwatch.metric_mapper
      end
    end
  end
end

ActiveSupport.on_load(:solid_queue) { Speedshop::Cloudwatch::SolidQueue.setup_lifecycle_hooks } if defined?(ActiveSupport)
