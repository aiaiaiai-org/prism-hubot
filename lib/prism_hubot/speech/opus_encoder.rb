# © 2026 aiaiaiai · aiaiaiai.org

require "open3"
require "timeout"

module PrismHubot
  module Speech
    # PCM WAV to Ogg/Opus, the only format Telegram plays as a voice message, with `opusenc` (Xiph
    # opus-tools) reading stdin and writing stdout. No shell, no files, no network: the audio only
    # passes through the process's pipes, and the process is killed if it runs past its limit.
    class OpusEncoder
      TIMEOUT_SECONDS = 60
      MAX_OUTPUT_BYTES = 50 * 1024 * 1024

      def initialize(executable: "opusenc", bitrate_kbps: 32, timeout: TIMEOUT_SECONDS)
        @command = [executable, "--quiet", "--speech", "--bitrate", bitrate_kbps.to_s, "-", "-"].freeze
        @timeout = timeout
      end

      def call(wav)
        output, status = run(wav.bytes)
        unless status.success? && output.start_with?("OggS".b) && output.byteslice(0, 128).include?("OpusHead".b)
          raise Failure.new(:encoding)
        end

        output
      end

      private

      def run(input)
        Open3.popen3(*@command) do |stdin, stdout, stderr, waiter|
          writer = Thread.new do
            stdin.binmode.write(input)
          rescue Errno::EPIPE
            nil
          ensure
            stdin.close unless stdin.closed?
          end
          drain = Thread.new { stderr.read }
          begin
            output = Timeout.timeout(@timeout) { stdout.binmode.read(MAX_OUTPUT_BYTES + 1) || "".b }
            raise Failure.new(:encoding) if output.bytesize > MAX_OUTPUT_BYTES

            [output, waiter.value]
          rescue Timeout::Error
            Process.kill("KILL", waiter.pid) rescue nil
            raise Failure.new(:timeout)
          ensure
            writer.kill
            drain.kill
          end
        end
      rescue Errno::ENOENT, Errno::EACCES
        raise Failure.new(:encoding)
      end
    end
  end
end
