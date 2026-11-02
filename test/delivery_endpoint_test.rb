# © 2026 aiaiaiai · aiaiaiai.org

require_relative "test_helper"
require "stringio"
require "rack/content_length"

class DeliveryEndpointTest < Minitest::Test
  include PrismHubotTestSupport

  SECRET_VALUE = "s" * 32

  class BlockingOutboundDelivery
    attr_reader :calls

    def initialize
      @calls = []
      @started = Queue.new
      @release = Queue.new
    end

    def wait_until_called
      @started.pop
    end

    def release
      @release << true
    end

    def deliver_message(chat_id:, text:, idempotency_key:, message_thread_id: nil)
      @calls << {
        chat_id: chat_id,
        text: text,
        idempotency_key: idempotency_key,
        message_thread_id: message_thread_id
      }
      @started << true
      @release.pop
      PrismBot::Domain::DeliveryResult.new(provider_message_id: 42, idempotency_key: idempotency_key)
    end
  end

  def test_responses_survive_rack_content_length
    Dir.mktmpdir do |directory|
      endpoint = build_endpoint(
        outbound_delivery: PrismHubotTestSupport::FakeOutboundDelivery.new,
        idempotency_store: build_idempotency_store(directory),
        max_body_bytes: 65_536
      )
      # rackup always wraps the app in Rack::ContentLength, which adds a header.
      status, headers, = Rack::ContentLength.new(endpoint).call(rack_env)

      assert_equal 200, status
      refute_predicate headers, :frozen?
      assert headers.key?("content-length")
    end
  end

  def test_wrong_method_is_not_found
    status, = call_endpoint(method: "GET")

    assert_equal 404, status
  end

  def test_missing_secret_is_unauthorized
    status, = call_endpoint(secret: nil)

    assert_equal 401, status
  end

  def test_wrong_secret_is_unauthorized
    status, = call_endpoint(secret: "x" * 32)

    assert_equal 401, status
  end

  def test_wrong_content_type_is_unsupported
    status, = call_endpoint(content_type: "text/plain")

    assert_equal 415, status
  end

  def test_oversized_body_is_rejected
    outbound_delivery = PrismHubotTestSupport::FakeOutboundDelivery.new
    status, = call_endpoint(outbound_delivery: outbound_delivery, max_body_bytes: 10)

    assert_equal 413, status
    assert_empty outbound_delivery.calls
  end

  def test_malformed_json_is_a_bad_request
    status, _headers, body = call_endpoint(body: "not json")

    assert_equal 400, status
    assert_equal "prism_hubot.delivery.json.invalid", parse(body).dig("error", "code")
  end

  def test_missing_field_is_a_bad_request
    status, _headers, body = call_endpoint(payload: {"chat_id" => 1, "text" => "hi"})

    assert_equal 400, status
    assert_equal "prism_hubot.delivery.request.invalid", parse(body).dig("error", "code")
  end

  def test_unknown_field_is_a_bad_request
    status, = call_endpoint(payload: default_payload.merge("extra" => "nope"))

    assert_equal 400, status
  end

  def test_invalid_message_thread_id_is_a_bad_request
    status, _headers, body = call_endpoint(payload: default_payload.merge("message_thread_id" => 0))

    assert_equal 400, status
    assert_equal "prism_hubot.delivery.thread.invalid", parse(body).dig("error", "code")
  end

  def test_a_request_rejected_before_reservation_never_touches_the_idempotency_store
    Dir.mktmpdir do |directory|
      idempotency_store = build_idempotency_store(directory)
      endpoint = build_endpoint(outbound_delivery: PrismHubotTestSupport::FakeOutboundDelivery.new, idempotency_store: idempotency_store)

      endpoint.call(rack_env(payload: {"chat_id" => 1, "text" => "hi"}))

      assert_empty Dir.children(directory)
    end
  end

  def test_successful_delivery
    outbound_delivery = PrismHubotTestSupport::FakeOutboundDelivery.new
    status, _headers, body = call_endpoint(outbound_delivery: outbound_delivery, payload: default_payload)

    assert_equal 200, status
    delivery = parse(body).fetch("delivery")
    assert_equal "digest-chunk-1", delivery.fetch("idempotency_key")
    assert_equal 42, delivery.fetch("provider_message_id")
    assert_equal(
      {chat_id: -1001, text: "hello", idempotency_key: "digest-chunk-1", message_thread_id: 7},
      outbound_delivery.calls.fetch(0)
    )
  end

  def test_repeated_idempotency_key_replays_the_completed_result
    outbound_delivery = PrismHubotTestSupport::FakeOutboundDelivery.new
    Dir.mktmpdir do |directory|
      endpoint = build_endpoint(outbound_delivery: outbound_delivery, idempotency_store: build_idempotency_store(directory))

      first_status, _headers, first_body = endpoint.call(rack_env(payload: default_payload))
      second_status, _headers, second_body = endpoint.call(rack_env(payload: default_payload))

      assert_equal 200, first_status
      assert_equal 200, second_status
      assert_equal parse(first_body), parse(second_body)
      assert_equal 1, outbound_delivery.calls.length
    end
  end

  def test_concurrent_duplicate_is_serialized_without_a_second_telegram_call
    outbound_delivery = BlockingOutboundDelivery.new
    Dir.mktmpdir do |directory|
      endpoint = build_endpoint(outbound_delivery: outbound_delivery, idempotency_store: build_idempotency_store(directory))
      first = Thread.new { endpoint.call(rack_env(payload: default_payload)) }
      outbound_delivery.wait_until_called

      second = Thread.new { endpoint.call(rack_env(payload: default_payload)) }
      sleep 0.01

      assert_equal 1, outbound_delivery.calls.length

      outbound_delivery.release
      first_status, _headers, first_body = first.value
      second_status, _headers, second_body = second.value

      assert_equal 200, first_status
      assert_equal 200, second_status
      assert_equal parse(first_body), parse(second_body)
      assert_equal 1, outbound_delivery.calls.length
    end
  end

  def test_a_released_reservation_lets_the_next_attempt_call_telegram
    outbound_delivery = PrismHubotTestSupport::FakeOutboundDelivery.new(
      error: PrismBot::MessageDeliveryError.new("bot.telegram.unavailable", "Telegram is unavailable")
    )
    Dir.mktmpdir do |directory|
      endpoint = build_endpoint(outbound_delivery: outbound_delivery, idempotency_store: build_idempotency_store(directory))

      first_status, = endpoint.call(rack_env(payload: default_payload))
      second_status, = endpoint.call(rack_env(payload: default_payload))

      assert_equal 502, first_status
      assert_equal 502, second_status
      assert_equal 2, outbound_delivery.calls.length
    end
  end

  def test_rate_limited_upstream_is_reported_as_too_many_requests
    outbound_delivery = PrismHubotTestSupport::FakeOutboundDelivery.new(
      error: PrismBot::DeliveryRateLimited.new(
        "bot.telegram.rate_limited",
        "Telegram rate limited delivery",
        retry_after_seconds: 5
      )
    )
    status, _headers, body = call_endpoint(outbound_delivery: outbound_delivery)

    assert_equal 429, status
    error = parse(body).fetch("error")
    assert_equal "bot.telegram.rate_limited", error.fetch("code")
    assert_equal 5, error.fetch("retry_after_seconds")
  end

  def test_upstream_delivery_failure_is_reported_as_bad_gateway
    outbound_delivery = PrismHubotTestSupport::FakeOutboundDelivery.new(
      error: PrismBot::MessageDeliveryError.new("bot.telegram.unavailable", "Telegram is unavailable")
    )
    status, = call_endpoint(outbound_delivery: outbound_delivery)

    assert_equal 502, status
  end

  def test_upstream_input_error_is_a_bad_request
    outbound_delivery = PrismHubotTestSupport::FakeOutboundDelivery.new(
      error: PrismBot::InputError.new("bot.telegram.delivery.invalid", "outbound Telegram delivery is invalid")
    )
    status, = call_endpoint(outbound_delivery: outbound_delivery)

    assert_equal 400, status
  end

  private

  def default_payload
    {
      "chat_id" => -1001,
      "message_thread_id" => 7,
      "text" => "hello",
      "idempotency_key" => "digest-chunk-1"
    }
  end

  def build_idempotency_store(directory)
    PrismHubot::DeliveryIdempotencyStore.new(directory: directory, ttl_seconds: 900, reservation_ttl_seconds: 30)
  end

  def build_endpoint(outbound_delivery:, idempotency_store:, max_body_bytes: 65_536)
    PrismHubot::DeliveryEndpoint.new(
      secret: PrismHubot::DeliverySecret.new(SECRET_VALUE),
      outbound_delivery: outbound_delivery,
      idempotency_store: idempotency_store,
      max_body_bytes: max_body_bytes,
      logger: Logger.new(File::NULL)
    )
  end

  def call_endpoint(
    outbound_delivery: PrismHubotTestSupport::FakeOutboundDelivery.new,
    max_body_bytes: 65_536,
    **request_options
  )
    Dir.mktmpdir do |directory|
      endpoint = build_endpoint(
        outbound_delivery: outbound_delivery,
        idempotency_store: build_idempotency_store(directory),
        max_body_bytes: max_body_bytes
      )
      endpoint.call(rack_env(**request_options))
    end
  end

  def rack_env(method: "POST", secret: SECRET_VALUE, content_type: "application/json", body: nil, payload: nil)
    source = body || JSON.generate(payload || default_payload)
    env = {
      "REQUEST_METHOD" => method,
      "CONTENT_TYPE" => content_type,
      "rack.input" => StringIO.new(source)
    }
    env["HTTP_X_PRISM_BOT_DELIVERY_SECRET"] = secret unless secret.nil?
    env
  end

  def parse(body)
    JSON.parse(body.join)
  end
end
