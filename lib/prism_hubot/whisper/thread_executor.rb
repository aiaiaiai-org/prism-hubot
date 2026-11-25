# © 2026 aiaiaiai · aiaiaiai.org

module PrismHubot
  module Whisper
    # A small, bounded pool for work that must not run inside Telegram's webhook request: synthesis
    # takes longer than Telegram waits for an answer, and an unanswered update is sent again. Workers
    # start on first use; a full queue refuses the job (the caller says "busy") instead of growing.
    class ThreadExecutor
      def initialize(workers: 2, capacity: 6)
        @workers = workers
        @queue = SizedQueue.new(capacity)
        @mutex = Mutex.new
        @threads = []
      end

      # true if the job was accepted, false if the queue is full.
      def post(&job)
        start_workers
        @queue.push(job, true)
        true
      rescue ThreadError
        false
      end

      private

      def start_workers
        @mutex.synchronize do
          return unless @threads.empty?

          @threads = Array.new(@workers) do
            Thread.new do
              loop do
                job = @queue.pop
                begin
                  job.call
                rescue => error
                  warn "whisper_executor job_failed class=#{error.class.name}"
                end
              end
            end
          end
        end
      end
    end
  end
end
