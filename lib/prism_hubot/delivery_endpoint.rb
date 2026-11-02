# © 2026 aiaiaiai · aiaiaiai.org

module PrismHubot
  # Rack endpoint for `POST /api/v1/delivery`: the receiving side of Prism
  # Hub's `PrismHub::Adapters::HttpBotDeliveryGateway`. Hub's delivery worker
  # resolves a `TelegramSurfaceBinding`, renders chunks through Porter, and
  # pushes each chunk here to be relayed to Telegram — this client never
  # decides what gets sent or to whom, only that the caller is Hub and that
  # each chunk is not knowingly relayed twice (see `DeliveryIdempotencyStore`
  # for the one crash window that best-effort claim cannot close).
  #
  # This is a separate Rack app from `PrismBot::Channels::Telegram::WebhookApp`
  # (mounted at a different path by `config.ru`), not a route added to it: the
  # two have unrelated callers, unrelated secrets, and unrelated payload
  # shapes, and the gem's webhook app is not the place to teach Hub-flavored
  # concerns to a Telegram-flavored one.
  class DeliveryEndpoint
    JSON_HEADERS = {
      "cache-control" => "no-store",
      "content-type" => "application/json; charset=utf-8"
    }.freeze
    REQUIRED_FIELDS = %w[chat_id text idempotency_key].freeze
    OPTIONAL_FIELDS = %w[message_thread_id].freeze

    def initialize(secret:, outbound_delivery:, idempotency_store:, max_body_bytes:, logger:)
      @secret = secret
      @outbound_delivery = outbound_delivery
      @idempotency_store = idempotency_store
      @max_body_bytes = Integer(max_body_bytes)
      @logger = logger
      raise ArgumentError, "max_body_bytes must be positive" unless @max_body_bytes.positive?
    end

    def call(environment)
      unless environment.fetch("REQUEST_METHOD") == "POST"
        return response(404, "status" => "error", "error" => {"code" => "prism_hubot.delivery.route.not_found"})
      end
      unless @secret.valid?(environment["HTTP_X_PRISM_BOT_DELIVERY_SECRET"])
        return response(401, "status" => "error", "error" => {"code" => "prism_hubot.delivery.secret.invalid"})
      end
      unless media_type(environment["CONTENT_TYPE"]) == "application/json"
        return response(415, "status" => "error", "error" => {"code" => "prism_hubot.delivery.content_type.invalid"})
      end

      source = environment.fetch("rack.input").read(@max_body_bytes + 1)
      if source.bytesize > @max_body_bytes
        return response(413, "status" => "error", "error" => {"code" => "prism_hubot.delivery.payload.too_large"})
      end

      chat_id, message_thread_id, text, idempotency_key = validate!(JSON.parse(source))
      deliver(chat_id: chat_id, message_thread_id: message_thread_id, text: text, idempotency_key: idempotency_key)
    rescue KeyError
      response(400, "status" => "error", "error" => {"code" => "prism_hubot.delivery.request.invalid"})
    rescue JSON::ParserError
      response(400, "status" => "error", "error" => {"code" => "prism_hubot.delivery.json.invalid"})
    rescue PrismBot::InputError => error
      response(400, "status" => "error", "error" => {"code" => error.code})
    end

    private

    def deliver(chat_id:, message_thread_id:, text:, idempotency_key:)
      @idempotency_store.with_key_lock(idempotency_key) do
        reservation = @idempotency_store.reserve(idempotency_key: idempotency_key)
        if reservation.completed?
          next success(idempotency_key, reservation.provider_message_id)
        elsif reservation.in_progress?
          next response(409, "status" => "error", "error" => {"code" => "prism_hubot.delivery.in_progress"})
        end

        begin
          result = @outbound_delivery.deliver_message(
            chat_id: chat_id,
            text: text,
            message_thread_id: message_thread_id,
            idempotency_key: idempotency_key
          )
          @idempotency_store.complete!(idempotency_key: idempotency_key, provider_message_id: result.provider_message_id)
          success(idempotency_key, result.provider_message_id)
        rescue PrismBot::InputError => error
          @idempotency_store.release(idempotency_key: idempotency_key)
          response(400, "status" => "error", "error" => {"code" => error.code})
        rescue PrismBot::DeliveryRateLimited => error
          @idempotency_store.release(idempotency_key: idempotency_key)
          response(429, "status" => "error", "error" => {
            "code" => error.code,
            "retry_after_seconds" => error.retry_after_seconds
          })
        rescue PrismBot::Error => error
          @idempotency_store.release(idempotency_key: idempotency_key)
          @logger.warn("prism_hubot_delivery upstream_error code=#{error.code}")
          response(502, "status" => "error", "error" => {"code" => error.code})
        end
      end
    end

    def success(idempotency_key, provider_message_id)
      response(200, "status" => "ok", "delivery" => {
        "idempotency_key" => idempotency_key,
        "provider_message_id" => provider_message_id
      })
    end

    def validate!(payload)
      unless payload.is_a?(Hash)
        raise PrismBot::InputError.new("prism_hubot.delivery.request.invalid", "delivery request must be a JSON object")
      end

      allowed = REQUIRED_FIELDS + OPTIONAL_FIELDS
      unless (payload.keys - allowed).empty? && (REQUIRED_FIELDS - payload.keys).empty?
        raise PrismBot::InputError.new("prism_hubot.delivery.request.invalid", "delivery request contains unsupported or missing fields")
      end

      thread = payload["message_thread_id"]
      unless thread.nil? || (thread.is_a?(Integer) && thread.positive?)
        raise PrismBot::InputError.new("prism_hubot.delivery.thread.invalid", "message_thread_id must be a positive integer or null")
      end

      [payload.fetch("chat_id"), thread, payload.fetch("text"), payload.fetch("idempotency_key")]
    end

    def media_type(content_type)
      String(content_type).split(";").first.to_s.strip.downcase
    end

    def response(status, body)
      # Rack 3 response headers must be mutable; Rack::ContentLength, which rackup always adds,
      # writes to them. Every response gets its own copy.
      [status, JSON_HEADERS.dup, [JSON.generate(body)]]
    end
  end
end
