# © 2026 aiaiaiai · aiaiaiai.org

module PrismHubot
  module Speech
    # The PCM WAV the speech service returns. Only what is needed is read: that it is a WAV of
    # uncompressed 16-bit samples, and how long it plays. Anything else is not trusted as audio.
    class Wav
      MAX_SECONDS = 300

      attr_reader :bytes, :duration_seconds

      # Raises Failure(:rejected) when the bytes are not a complete PCM16 WAV within the length limit.
      def self.parse(bytes)
        data = bytes.b
        raise Failure.new(:rejected) unless data.bytesize >= 44 && data.start_with?("RIFF".b) &&
          data.byteslice(8, 4) == "WAVE".b

        fmt = nil
        offset = 12
        while offset + 8 <= data.bytesize
          id = data.byteslice(offset, 4)
          size = data.byteslice(offset + 4, 4).unpack1("V")
          body = offset + 8
          case id
          when "fmt ".b
            raise Failure.new(:rejected) if size < 16 || body + 16 > data.bytesize

            fmt = data.byteslice(body, 16).unpack("vvVVvv")
          when "data".b
            raise Failure.new(:rejected) unless fmt && body + size <= data.bytesize

            return from(data, fmt, size)
          end
          offset = body + size + (size.odd? ? 1 : 0)
        end
        raise Failure.new(:rejected)
      end

      def self.from(data, fmt, data_size)
        format, channels, _rate, byte_rate, _align, bits = fmt
        raise Failure.new(:rejected) unless format == 1 && bits == 16 && channels.between?(1, 2) && byte_rate.positive?

        seconds = (data_size.to_f / byte_rate).ceil
        raise Failure.new(:rejected) unless data_size.positive? && seconds <= MAX_SECONDS

        new(data, [seconds, 1].max)
      end
      private_class_method :from

      def initialize(bytes, duration_seconds)
        @bytes = bytes.freeze
        @duration_seconds = duration_seconds
        freeze
      end
    end
  end
end
