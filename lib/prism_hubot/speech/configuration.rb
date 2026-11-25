# © 2026 aiaiaiai · aiaiaiai.org

module PrismHubot
  module Speech
    # Speech is optional and all-or-nothing. With no PRISM_HUBOT_TTS_URL Whisper still works and says
    # voice is unavailable; with a URL but a missing credential the process refuses to start, so a
    # half-configured release is visible at deployment and not at the first person's request.
    #
    #   PRISM_HUBOT_TTS_URL             URL of prism-ai's POST /v1/speech: https, or http to a Docker network alias
    #                                   on this server (a single-label host such as prism-ai-tts)
    #   PRISM_HUBOT_TTS_VOICE           voice alias the service knows (default uk-UA)
    #   PRISM_HUBOT_AIS_CLIENT_ID       this product's AIS client id (as registered in 4x-ais, e.g. prism-hubot)
    #   PRISM_HUBOT_AIS_KEY_ID          the `kid` the public half of the key is registered under (default k1)
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
        endpoint!(url, private_network: true)
        endpoint!(token_url)

        key_id = environment.fetch("PRISM_HUBOT_AIS_KEY_ID", AisTokenSource::DEFAULT_KEY_ID).to_s.strip
        unless AisTokenSource::KEY_ID.match?(key_id)
          raise PrismBot::ConfigurationError.new(
            "prism_hubot.speech.key_id.invalid", "PRISM_HUBOT_AIS_KEY_ID must be 1-64 letters, digits, - or _"
          )
        end

        tokens = AisTokenSource.new(
          client_id: environment.fetch("PRISM_HUBOT_AIS_CLIENT_ID").strip, key_id: key_id,
          private_key_pem: environment.fetch("PRISM_HUBOT_AIS_PRIVATE_KEY"),
          token_url: token_url, audience: AUDIENCE, scope: SCOPE, http: http
        )
        voice = environment.fetch("PRISM_HUBOT_TTS_VOICE", DEFAULT_VOICE).to_s.strip
        Voice.new(
          synthesizer: HttpSynthesizer.new(url: url, voice: voice, tokens: tokens, http: http), encoder: encoder
        )
      end

      def self.endpoint!(value, private_network: false)
        return if Endpoint.permitted?(URI(value), private_network: private_network)

        raise ArgumentError
      rescue URI::InvalidURIError, ArgumentError
        raise PrismBot::ConfigurationError.new(
          "prism_hubot.speech.url.invalid",
          private_network ? "the speech URL must be https, or http to a private network alias" : "speech URLs must be https URLs"
        )
      end
      private_class_method :endpoint!
    end
  end
end
