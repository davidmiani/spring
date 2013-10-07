module Spring
  module Watcher
    class Polling < Abstract
      attr_reader :mtime

      def initialize(root, latency)
        super
        @mtime  = 0
        @poller = nil
        @env = Env.new
      end

      def check_stale
        synchronize {
          current = compute_mtime

          if mtime < current
            @env.log "[polling watcher] mtime: #{mtime}, new mtime: #{current}"
            mark_stale
          end
        }
      end

      def add(*)
        check_stale if @poller
        super
      end

      def start
        unless @poller
          @poller = Thread.new {
            Thread.current.abort_on_exception = true

            loop do
              Kernel.sleep latency
              check_stale
            end
          }
        end
      end

      def stop
        if @poller
          @poller.kill
          @poller = nil
        end
      end

      def subjects_changed
        @mtime = compute_mtime
      end

      private

      def compute_mtime
        expanded_files.map { |f| File.mtime(f).to_f }.max || 0
      rescue Errno::ENOENT => e
        @env.log "[polling watcher] ENOENT: #{e.inspect}"
        # if a file does no longer exist, the watcher is always stale.
        Float::MAX
      end

      def expanded_files
        files + Dir["{#{directories.map { |d| "#{d}/**/*" }.join(",")}}"]
      end
    end
  end
end
