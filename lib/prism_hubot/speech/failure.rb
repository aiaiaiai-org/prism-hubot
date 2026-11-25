# © 2026 aiaiaiai · aiaiaiai.org

module PrismHubot
  module Speech
    # Why a voice could not be made. The code is for the person's private message and for the
    # operator's redacted log; it never carries message text, audio, tokens or response bodies.
    class Failure < StandardError
      CODES = %i[unavailable busy too_long rejected timeout encoding].freeze

      attr_reader :code

      def initialize(code)
        raise ArgumentError, "unknown speech failure" unless CODES.include?(code)

        @code = code
        super("speech failed: #{code}")
      end
    end
  end
end
