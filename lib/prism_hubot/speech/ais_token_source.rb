# © 2026 aiaiaiai · aiaiaiai.org

require "base64"
require "openssl"

module PrismHubot
  module Speech
    # A product access token from AIS: `client_credentials` with `private_key_jwt` (RFC 7523), signed
    # with the product's own Ed25519 key, for one audience and scope. The token is kept only in memory
    # and reused until shortly before it expires. There is no shared secret and nothing is persisted.
    #
    # Checked against AIS's source (aiaiaiai-org/4x-ais: docs/runtime.md, src/product_token.rs and the
    # `client_credentials` branch of src/issuer.rs): the form carries grant_type, client_assertion_type,
    # client_assertion, `audience` and `scope` (never a secret); the assertion's header needs `alg: EdDSA`
    # and the `kid` of a key registered for this client; its claims are iss = sub = client_id, aud = the
    # token endpoint, a 16-128 character jti and exp at most five minutes ahead. The answer is an `at+jwt`
    # access token for that audience and the granted scopes, valid for 300 seconds.
    class AisTokenSource
      ASSERTION_TYPE = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer".freeze
      ASSERTION_LIFETIME = 60
      REFRESH_MARGIN = 30
      MAX_LIFETIME = 300
      MAX_RESPONSE_BYTES = 16 * 1024

      DEFAULT_KEY_ID = "k1".freeze
      KEY_ID = /\A[A-Za-z0-9_-]{1,64}\z/

      def initialize(client_id:, private_key_pem:, token_url:, audience:, scope:, key_id: DEFAULT_KEY_ID, http: Http.new,
        clock: -> { Time.now.to_i }, jti: -> { SecureRandom.uuid })
        raise ArgumentError, "key_id is invalid" unless KEY_ID.match?(key_id.to_s)

        @client_id = client_id
        @key_id = key_id
        @key = load_key(private_key_pem)
        @token_url = token_url
        @audience = audience
        @scope = scope
        @http = http
        @clock = clock
        @jti = jti
        @mutex = Mutex.new
        @token = nil
        @expires_at = 0
      end

      # A bearer token, fetched again when the cached one is about to expire or after #reject.
      def call
        @mutex.synchronize do
          now = @clock.call
          fetch(now) if @token.nil? || now >= @expires_at - REFRESH_MARGIN
          @token
        end
      end

      # The caller was told the token is not valid (for example the key was rotated): forget it.
      def reject
        @mutex.synchronize { @token = nil }
      end

      private

      def fetch(now)
        response = @http.post(
          @token_url,
          headers: {"content-type" => "application/x-www-form-urlencoded", "accept" => "application/json"},
          body: URI.encode_www_form(request_fields(now)),
          max_bytes: MAX_RESPONSE_BYTES
        )
        raise Failure.new(:unavailable) unless response.status == 200

        document = JSON.parse(response.body)
        token = document["access_token"]
        lifetime = document["expires_in"]
        unless token.is_a?(String) && !token.empty? && lifetime.is_a?(Integer) && lifetime.positive?
          raise Failure.new(:unavailable)
        end

        @token = token
        @expires_at = now + [lifetime, MAX_LIFETIME].min
      rescue JSON::ParserError
        raise Failure.new(:unavailable)
      end

      def request_fields(now)
        {
          "grant_type" => "client_credentials",
          "client_assertion_type" => ASSERTION_TYPE,
          "client_assertion" => assertion(now),
          "scope" => @scope,
          "audience" => @audience
        }
      end

      def assertion(now)
        header = {"alg" => "EdDSA", "typ" => "JWT", "kid" => @key_id}
        claims = {"iss" => @client_id, "sub" => @client_id, "aud" => @token_url, "jti" => @jti.call,
                  "iat" => now, "exp" => now + ASSERTION_LIFETIME}
        signing_input = [header, claims].map { base64url(JSON.generate(_1)) }.join(".")
        "#{signing_input}.#{base64url(@key.sign(nil, signing_input))}"
      end

      def base64url(value)
        Base64.urlsafe_encode64(value, padding: false)
      end

      # The key as PEM, with `\n` escapes if it had to be one line, or the whole PEM base64-encoded: a
      # sealed secret travels as one `NAME=value` line, so a multi-line PEM cannot be stored as it is.
      def load_key(value)
        pem = value.to_s.strip
        pem = Base64.strict_decode64(pem) unless pem.include?("BEGIN")
        key = OpenSSL::PKey.read(pem.gsub("\\n", "\n"))
        raise ArgumentError unless key.respond_to?(:oid) && key.oid == "ED25519"

        key.sign(nil, "probe") # a public-only key cannot sign: it is refused here, not at the first request
        key
      rescue OpenSSL::PKey::PKeyError, ArgumentError
        raise PrismBot::ConfigurationError.new(
          "prism_hubot.speech.key.invalid", "the AIS client key must be an Ed25519 private key in PEM form (or base64 of it)"
        )
      end
    end
  end
end
