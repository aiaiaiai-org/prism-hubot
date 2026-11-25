# © 2026 aiaiaiai · aiaiaiai.org

require "bundler/setup"
require_relative "lib/prism_hubot"

configuration = PrismHubot::Configuration.new(ENV)
state_store = PrismHubot::FileInteractionStateStore.new(
  directory: configuration.state_directory,
  ttl_seconds: configuration.state_ttl_seconds
)
# Text-to-speech is optional: without PRISM_HUBOT_TTS_URL Whisper lists and chooses but cannot speak.
speech = PrismHubot::Speech::Configuration.build(ENV)
client = PrismHubot::Client.new(state_store: state_store, speech: speech)

app = PrismBot::Bootstrap.build(env: ENV, client: client)

# Optional: receives chunks Prism Hub's delivery worker pushes for a bound
# Telegram surface (`PrismHub::Adapters::HttpBotDeliveryGateway`). Absent
# PRISM_BOT_DELIVERY_SECRET, no such worker is wired to this deployment yet,
# so no route is mounted — see docs/deploy.md#receiving-hub-deliveries.
delivery_configuration = PrismHubot::DeliveryConfiguration.from_environment(ENV)
if delivery_configuration
  bot_configuration = PrismBot::Configuration.new(ENV)
  outbound_delivery = PrismBot::Adapters::Telegram::BotApiClient.new(
    token: bot_configuration.telegram_token,
    transport: PrismBot::Adapters::NetHttpTransport.new(
      allow_insecure_http: bot_configuration.allow_insecure_http
    )
  )
  delivery_endpoint = PrismHubot::DeliveryEndpoint.new(
    secret: delivery_configuration.secret,
    outbound_delivery: outbound_delivery,
    idempotency_store: PrismHubot::DeliveryIdempotencyStore.new(
      directory: delivery_configuration.idempotency_directory,
      ttl_seconds: delivery_configuration.idempotency_ttl_seconds,
      reservation_ttl_seconds: delivery_configuration.reservation_ttl_seconds
    ),
    max_body_bytes: delivery_configuration.max_body_bytes,
    logger: Logger.new($stdout)
  )
  app = Rack::URLMap.new("/api/v1/delivery" => delivery_endpoint, "/" => app)
end

run app
