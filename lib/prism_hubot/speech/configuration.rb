# © 2026 aiaiaiai · aiaiaiai.org

module PrismHubot
  module Speech
    # Speech is optional and all-or-nothing. With no PRISM_HUBOT_TTS_URL Whisper still works and says
    # voice is unavailable; with a URL but a missing credential the process refuses to start, so a
    # half-configured release is visible at deployment and not at the first person's request.
    #
    #   PRISM_HUBOT_TTS_URL             https URL of prism-ai's POST /v1/speech
    #   PRISM_HUBOT_TTS_VOICE           voice alias the service knows (default uk-UA)
    #   PRISM_HUBOT_AIS_CLIENT_ID       this product's AIS client id
    #   PRISM_HUBOT_AIS_PRIVATE_KEY     its Ed25519 private key, PEM (secret; \n escapes allowed)
    #   PRISM_HUBOT_AIS_TOKEN_URL       AIS token endpoint (default https://auth.aiaiaiai.org/token)
    class Configuration
      DEFAULT_VOICE = "uk-UA".freeze
      DEFAULT_TOKEN_URL = "https://auth.aiaiaiai.org/token".freeze
      AUDIENCE = "prism-ai".freeze
      SCOPE = "tts.synthesize".freeze
      REQUIRED = %w[PRISM_HUBOT_AIS_CLIENT_ID PRISM_HUBOT_AIS_PRIVATE_KEY].freeze

      # The Voice, or nil when speech is not configured.
      def self.build(environment, http: Http.new, encoder: OpusEncoder.new)
        url = environment.fetch("PRISM_HUBOT_TTS_URL", "").to_s.strip
        return nil if url.empty?

        missing = REQUIRED.select { environment.fetch(_1, "").to_s.strip.empty? }
        unless missing.empty?
          raise PrismBot::ConfigurationError.new(
            "prism_hubot.speech.incomplete", "speech needs #{missing.join(" and ")} as well as PRISM_HUBOT_TTS_URL"
          )
        end
        token_url = environment.fetch("PRISM_HUBOT_AIS_TOKEN_URL", DEFAULT_TOKEN_URL).to_s.strip
        [url, token_url].each { https!(_1) }

        tokens = AisTokenSource.new(
          client_id: environment.fetch("PRISM_HUBOT_AIS_CLIENT_ID").strip,
          private_key_pem: environment.fetch("PRISM_HUBOT_AIS_PRIVATE_KEY"),
          token_url: token_url, audience: AUDIENCE, scope: SCOPE, http: http
        )
        voice = environment.fetch("PRISM_HUBOT_TTS_VOICE", DEFAULT_VOICE).to_s.strip
        Voice.new(
          synthesizer: HttpSynthesizer.new(url: url, voice: voice, tokens: tokens, http: http), encoder: encoder
        )
      end

      def self.https!(value)
        uri = URI(value)
        return if uri.is_a?(URI::HTTPS) && uri.host

        raise ArgumentError
      rescue URI::InvalidURIError, ArgumentError
        raise PrismBot::ConfigurationError.new(
          "prism_hubot.speech.url.invalid", "speech URLs must be https URLs"
        )
      end
      private_class_method :https!
    end
  end
end
