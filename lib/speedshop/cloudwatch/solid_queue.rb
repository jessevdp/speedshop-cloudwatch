# frozen_string_literal: true

require "speedshop/cloudwatch/solid_queue_queues"
require "speedshop/cloudwatch/solid_queue_processes"

module Speedshop
  module Cloudwatch
    module SolidQueue
      def self.setup_lifecycle_hooks
        ::SolidQueue.on_start do |supervisor|
          SolidQueueProcesses.supervisor = supervisor
          Speedshop::Cloudwatch.configure { |config| config.collectors << :solid_queue_processes }
          Speedshop::Cloudwatch.start!
        end

        ::SolidQueue.on_stop { Speedshop::Cloudwatch.stop! }
        ::SolidQueue.on_exit { Speedshop::Cloudwatch.stop! }

        ::SolidQueue.on_dispatcher_start do
          Speedshop::Cloudwatch.configure { |config| config.collectors << :solid_queue_queues }
          Speedshop::Cloudwatch.start!
        end

        ::SolidQueue.on_dispatcher_stop { Speedshop::Cloudwatch.stop! }
        ::SolidQueue.on_dispatcher_exit { Speedshop::Cloudwatch.stop! }
      end
    end
  end
end

ActiveSupport.on_load(:solid_queue) { Speedshop::Cloudwatch::SolidQueue.setup_lifecycle_hooks } if defined?(ActiveSupport)
