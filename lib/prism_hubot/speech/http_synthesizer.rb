# © 2026 aiaiaiai · aiaiaiai.org

module PrismHubot
  module Speech
    # Text to PCM WAV through prism-ai's speech service (POST /v1/speech, exactly `text` and `voice`).
    # The text is sent once, over HTTPS, with a product token; it is never logged, kept or retried
    # with changes. The service refuses over-limit text instead of cutting it, and so does this.
    class HttpSynthesizer
      MAX_TEXT_CHARACTERS = 4_000
      MAX_RESPONSE_BYTES = 60 * 1024 * 1024

      def initialize(url:, voice:, tokens:, http: Http.new)
        @url = url
        @voice = voice
        @tokens = tokens
        @http = http
      end

      def call(text)
        raise Failure.new(:too_long) if text.length > MAX_TEXT_CHARACTERS || text.strip.empty?

        response = post(text)
        if response.status == 401
          # The cached token may have been revoked or its key rotated: ask once more with a new one.
          @tokens.reject
          response = post(text)
        end
        Wav.parse(accept(response))
      end

      private

      def post(text)
        @http.post(
          @url,
          headers: {"authorization" => "Bearer #{@tokens.call}", "content-type" => "application/json",
                    "accept" => "audio/wav"},
          body: JSON.generate("text" => text, "voice" => @voice),
          max_bytes: MAX_RESPONSE_BYTES
        )
      end

      def accept(response)
        case response.status
        when 200 then response.body
        when 429 then raise Failure.new(:busy)
        when 422 then raise Failure.new(:too_long)
        when 504 then raise Failure.new(:timeout)
        when 400..499 then raise Failure.new(:rejected)
        else raise Failure.new(:unavailable)
        end
      end
    end
  end
end
