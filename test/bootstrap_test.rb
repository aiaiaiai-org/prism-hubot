# © 2026 aiaiaiai · aiaiaiai.org

require "json"
require "minitest/autorun"
require "rack/mock"
require "tmpdir"
require_relative "../lib/prism_hubot"

class BootstrapTest < Minitest::Test
  def test_builds_runnable_concrete_client
    Dir.mktmpdir do |directory|
      state_store = PrismHubot::FileInteractionStateStore.new(
        directory: directory,
        ttl_seconds: 900
      )
      app = PrismBot::Bootstrap.build(
        env: environment,
        client: PrismHubot::Client.new(state_store: state_store),
        logger: Logger.new(IO::NULL)
      )

      response = Rack::MockRequest.new(app).get("/healthz")
      payload = JSON.parse(response.body)

      assert_equal 200, response.status
      assert_equal "ok", payload.fetch("status")
      assert_equal "prism-bot", payload.fetch("service")
    end
  end

  def test_client_defaults_are_explicit
    configuration = PrismBot::Configuration.new(environment)

    assert_equal "prism-hubot", configuration.instance_id
    assert_equal "uk-UA", configuration.default_locale
    assert_equal "0x0sky.uk_SP", configuration.default_voice_profile
    assert_equal "require_all_valid", configuration.dispatch_policy
  end

  def test_interaction_state_defaults_are_explicit
    configuration = PrismHubot::Configuration.new({})

    assert_equal File.expand_path("var/interaction-state"), configuration.state_directory
    assert_equal 900, configuration.state_ttl_seconds
  end

  def test_rejects_invalid_interaction_state_ttl
    error = assert_raises(PrismBot::ConfigurationError) do
      PrismHubot::Configuration.new(
        "PRISM_HUBOT_INTERACTION_STATE_TTL_SECONDS" => "0"
      )
    end

    assert_equal "prism_hubot.configuration.integer.invalid", error.code
  end

  private

  def environment
    {
      "PRISM_BOT_INSTANCE_ID" => "prism-hubot",
      "PRISM_BOT_TELEGRAM_TOKEN" => "telegram-test-token",
      "PRISM_BOT_TELEGRAM_WEBHOOK_SECRET" => "a" * 32,
      # prism-bot requires it; the bootstrap builds its delivery endpoint.
      "PRISM_BOT_DELIVERY_SECRET" => "d" * 32,
      "PRISM_BOT_TELEGRAM_ALLOWED_CHAT_IDS" => "[]",
      "PRISM_BOT_DEFAULT_CHANNEL_IDS" => "[]",
      "PRISM_BOT_DEFAULT_LOCALE" => "uk-UA",
      "PRISM_BOT_DEFAULT_VOICE_PROFILE" => "0x0sky.uk_SP",
      "PRISM_BOT_DISPATCH_POLICY" => "require_all_valid",
      "PRISM_HUB_BASE_URL" => "https://hub.example.test",
      "PRISM_HUB_API_TOKEN" => "h" * 32,
      "PRISM_BOT_MAX_WEBHOOK_BYTES" => "1048576",
      "PRISM_BOT_ALLOW_INSECURE_HTTP" => "false"
    }
  end
end
