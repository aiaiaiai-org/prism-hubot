# © 2026 aiaiaiai · aiaiaiai.org

module PrismHubot
  module Speech
    # Text to a native voice message: synthesize, encode, and wrap as the clip prism-bot sends.
    # The duration is the synthesized audio's length, rounded up to whole seconds as Telegram expects.
    class Voice
      def initialize(synthesizer:, encoder:)
        @synthesizer = synthesizer
        @encoder = encoder
      end

      def call(text)
        wav = @synthesizer.call(text)
        PrismBot::Domain::VoiceClip.new(audio: @encoder.call(wav), duration_seconds: wav.duration_seconds)
      rescue PrismBot::InputError
        raise Failure.new(:encoding)
      end
    end
  end
end
