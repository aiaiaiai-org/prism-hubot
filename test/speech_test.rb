# © 2026 aiaiaiai · aiaiaiai.org

require_relative "test_helper"

class SpeechTest < Minitest::Test
  Response = PrismHubot::Speech::Http::Response

  # Answers queued responses in order and records every request.
  class FakeHttp
    attr_reader :posts

    def initialize(*responses)
      @responses = responses
      @posts = []
    end

    def post(url, headers:, body:, max_bytes:)
      @posts << {url: url, headers: headers, body: body, max_bytes: max_bytes}
      response = @responses.shift or raise "unexpected request"
      raise response if response.is_a?(Exception)

      response
    end
  end

  def pcm16_wav(seconds: 2, rate: 22_050, channels: 1, format: 1, bits: 16)
    byte_rate = rate * channels * bits / 8
    data = "\0".b * (byte_rate * seconds)
    fmt = [format, channels, rate, byte_rate, channels * bits / 8, bits].pack("vvVVvv")
    body = "WAVE".b + "fmt ".b + [16].pack("V") + fmt + "data".b + [data.bytesize].pack("V") + data
    "RIFF".b + [body.bytesize].pack("V") + body
  end

  def ogg_opus
    "OggS".b + "\0" * 20 + "OpusHead".b + "\1\1".b + "\0" * 40
  end

  def failure_code(&block)
    error = assert_raises(PrismHubot::Speech::Failure, &block)
    error.code
  end

  # --- Wav ---------------------------------------------------------------------------------------

  def test_wav_reports_whole_seconds_rounded_up
    assert_equal 2, PrismHubot::Speech::Wav.parse(pcm16_wav(seconds: 2)).duration_seconds
    odd = pcm16_wav(seconds: 2).b
    odd[-4..] = "" # a little less than two seconds of samples is not a whole second either
    assert_equal 2, PrismHubot::Speech::Wav.parse(fix_sizes(odd)).duration_seconds
    assert_equal 1, PrismHubot::Speech::Wav.parse(fix_sizes(pcm16_wav(seconds: 1).byteslice(0, 60))).duration_seconds
  end

  def fix_sizes(wav)
    wav = wav.b
    wav[4, 4] = [wav.bytesize - 8].pack("V")
    wav[40, 4] = [wav.bytesize - 44].pack("V")
    wav
  end

  def test_wav_refuses_anything_that_is_not_complete_pcm16
    assert_equal :rejected, failure_code { PrismHubot::Speech::Wav.parse("not audio") }
    assert_equal :rejected, failure_code { PrismHubot::Speech::Wav.parse(pcm16_wav(format: 3)) }
    assert_equal :rejected, failure_code { PrismHubot::Speech::Wav.parse(pcm16_wav(bits: 8)) }
    assert_equal :rejected, failure_code { PrismHubot::Speech::Wav.parse(pcm16_wav(channels: 6)) }
    truncated = pcm16_wav(seconds: 2).b.byteslice(0, 1000)
    assert_equal :rejected, failure_code { PrismHubot::Speech::Wav.parse(truncated) }
    assert_equal :rejected, failure_code { PrismHubot::Speech::Wav.parse(pcm16_wav(seconds: 301, rate: 8_000)) }
  end

  # --- AIS token source ----------------------------------------------------------------------------

  def key
    @key ||= OpenSSL::PKey.generate_key("ED25519")
  end

  def token_source(http, now: [1_000], **options)
    PrismHubot::Speech::AisTokenSource.new(
      client_id: "prism-hubot", private_key_pem: key.private_to_pem,
      token_url: "https://auth.example.test/token", audience: "prism-ai", scope: "tts.synthesize",
      http: http, clock: -> { now.first }, jti: -> { "jti-1" }, **options
    )
  end

  def token_response(token = "tok-1", expires_in = 300)
    Response.new(status: 200, body: JSON.generate("access_token" => token, "token_type" => "Bearer", "expires_in" => expires_in))
  end

  def test_token_request_is_a_signed_private_key_jwt_for_one_audience_and_scope
    http = FakeHttp.new(token_response)
    assert_equal "tok-1", token_source(http).call

    post = http.posts.fetch(0)
    assert_equal "https://auth.example.test/token", post[:url]
    fields = URI.decode_www_form(post[:body]).to_h
    assert_equal "client_credentials", fields["grant_type"]
    assert_equal "urn:ietf:params:oauth:client-assertion-type:jwt-bearer", fields["client_assertion_type"]
    assert_equal "tts.synthesize", fields["scope"]
    assert_equal "prism-ai", fields["audience"]
    refute_includes post[:body], key.private_to_pem[0, 20], "the key never travels"

    header, claims, signature = fields["client_assertion"].split(".")
    decode = ->(part) { JSON.parse(Base64.urlsafe_decode64(part)) }
    assert_equal({"alg" => "EdDSA", "typ" => "JWT"}, decode.call(header))
    assert_equal({"iss" => "prism-hubot", "sub" => "prism-hubot", "aud" => "https://auth.example.test/token",
                  "jti" => "jti-1", "iat" => 1_000, "exp" => 1_060}, decode.call(claims))
    assert key.verify(nil, Base64.urlsafe_decode64(signature), "#{header}.#{claims}"), "signed by the product's own key"
  end

  def test_token_is_cached_until_shortly_before_it_expires_and_can_be_rejected
    now = [1_000]
    http = FakeHttp.new(token_response("a"), token_response("b"), token_response("c"))
    source = token_source(http, now: now)

    assert_equal "a", source.call
    now[0] = 1_200
    assert_equal "a", source.call
    assert_equal 1, http.posts.length
    now[0] = 1_280 # within 30 s of the 300 s lifetime
    assert_equal "b", source.call
    source.reject
    assert_equal "c", source.call
  end

  def test_token_lifetime_is_capped_at_five_minutes
    now = [1_000]
    http = FakeHttp.new(token_response("a", 86_400), token_response("b"))
    source = token_source(http, now: now)
    source.call
    now[0] = 1_290
    assert_equal "b", source.call
  end

  def test_token_failures_are_unavailable_and_never_quote_the_answer
    [Response.new(status: 401, body: "secret detail"), Response.new(status: 200, body: "not json"),
     Response.new(status: 200, body: JSON.generate("access_token" => "", "expires_in" => 300)),
     Response.new(status: 200, body: JSON.generate("access_token" => "t"))].each do |answer|
      error = assert_raises(PrismHubot::Speech::Failure) { token_source(FakeHttp.new(answer)).call }
      assert_equal :unavailable, error.code
      refute_includes error.message, "secret detail"
    end
  end

  def test_only_an_ed25519_private_key_is_accepted
    rsa = OpenSSL::PKey::RSA.new(2048).to_pem
    [rsa, "not a key", key.public_to_pem].each do |pem|
      assert_raises(PrismBot::ConfigurationError) do
        PrismHubot::Speech::AisTokenSource.new(client_id: "x", private_key_pem: pem, token_url: "https://a.test/t",
          audience: "prism-ai", scope: "tts.synthesize")
      end
    end
    escaped = key.private_to_pem.gsub("\n", "\\n")
    assert PrismHubot::Speech::AisTokenSource.new(client_id: "x", private_key_pem: escaped,
      token_url: "https://a.test/t", audience: "prism-ai", scope: "tts.synthesize")
  end

  def test_the_key_may_be_stored_as_one_line_of_base64
    encoded = Base64.strict_encode64(key.private_to_pem)
    refute_includes encoded, "\n"
    source = PrismHubot::Speech::AisTokenSource.new(client_id: "x", private_key_pem: encoded,
      token_url: "https://a.test/t", audience: "prism-ai", scope: "tts.synthesize", http: FakeHttp.new(token_response))
    assert_equal "tok-1", source.call
    assert_raises(PrismBot::ConfigurationError) do
      PrismHubot::Speech::AisTokenSource.new(client_id: "x", private_key_pem: Base64.strict_encode64("not a key"),
        token_url: "https://a.test/t", audience: "prism-ai", scope: "tts.synthesize")
    end
  end

  # --- Synthesizer -----------------------------------------------------------------------------------

  class Tokens
    attr_reader :rejected

    def initialize(*tokens)
      @tokens = tokens
      @rejected = 0
    end

    def call
      @tokens.first
    end

    def reject
      @rejected += 1
      @tokens.shift if @tokens.length > 1
    end
  end

  def synthesizer(http, tokens: Tokens.new("tok"))
    PrismHubot::Speech::HttpSynthesizer.new(url: "https://tts.example.test/v1/speech", voice: "uk-UA", tokens: tokens, http: http)
  end

  def test_synthesis_posts_exactly_text_and_voice_with_a_bearer_token
    http = FakeHttp.new(Response.new(status: 200, body: pcm16_wav(seconds: 3)))
    wav = synthesizer(http).call("Ада: привіт")

    assert_equal 3, wav.duration_seconds
    post = http.posts.fetch(0)
    assert_equal "https://tts.example.test/v1/speech", post[:url]
    assert_equal "Bearer tok", post[:headers]["authorization"]
    assert_equal({"text" => "Ада: привіт", "voice" => "uk-UA"}, JSON.parse(post[:body]))
  end

  def test_service_answers_become_failures_without_leaking_anything
    {429 => :busy, 422 => :too_long, 504 => :timeout, 403 => :rejected, 400 => :rejected, 500 => :unavailable,
     502 => :unavailable}.each do |status, code|
      http = FakeHttp.new(Response.new(status: status, body: "internal detail"))
      error = assert_raises(PrismHubot::Speech::Failure) { synthesizer(http).call("текст") }
      assert_equal code, error.code, "status #{status}"
      refute_includes error.message, "internal detail"
    end
  end

  def test_an_unauthorized_token_is_replaced_once
    http = FakeHttp.new(Response.new(status: 401, body: ""), Response.new(status: 200, body: pcm16_wav))
    tokens = Tokens.new("old", "new")
    synthesizer(http, tokens: tokens).call("текст")

    assert_equal ["Bearer old", "Bearer new"], http.posts.map { _1[:headers]["authorization"] }
    assert_equal 1, tokens.rejected

    twice = FakeHttp.new(Response.new(status: 401, body: ""), Response.new(status: 401, body: ""))
    assert_equal :rejected, failure_code { synthesizer(twice, tokens: Tokens.new("old", "new")).call("текст") }
    assert_equal 2, twice.posts.length
  end

  def test_text_over_the_limit_or_blank_is_refused_before_any_request
    http = FakeHttp.new
    assert_equal :too_long, failure_code { synthesizer(http).call("а" * 4_001) }
    assert_equal :too_long, failure_code { synthesizer(http).call("   ") }
    assert_empty http.posts
    assert synthesizer(FakeHttp.new(Response.new(status: 200, body: pcm16_wav))).call("а" * 4_000)
  end

  def test_audio_that_is_not_a_pcm_wav_is_rejected
    http = FakeHttp.new(Response.new(status: 200, body: "ID3 mp3 bytes"))
    assert_equal :rejected, failure_code { synthesizer(http).call("текст") }
  end

  def test_network_failures_pass_through_as_failures
    http = FakeHttp.new(PrismHubot::Speech::Failure.new(:timeout))
    assert_equal :timeout, failure_code { synthesizer(http).call("текст") }
  end

  # --- Encoder -------------------------------------------------------------------------------------

  def fake_encoder(script, **options)
    dir = Dir.mktmpdir
    path = File.join(dir, "opusenc")
    File.write(path, "#!/bin/sh\n#{script}\n")
    File.chmod(0o755, path)
    PrismHubot::Speech::OpusEncoder.new(executable: path, **options)
  end

  def wav
    PrismHubot::Speech::Wav.parse(pcm16_wav(seconds: 1))
  end

  def test_encoder_returns_ogg_opus_from_the_process
    encoder = fake_encoder(%(cat >/dev/null; printf 'OggS\\0\\0\\0\\0OpusHead\\1\\1\\0\\0'))
    assert encoder.call(wav).start_with?("OggS")
  end

  def test_encoder_feeds_the_wav_through_stdin
    encoder = fake_encoder(%(head -c 4 | grep -q RIFF && printf 'OggS\\0\\0\\0\\0OpusHead\\1\\1\\0\\0'; cat >/dev/null))
    assert encoder.call(wav).include?("OpusHead")
  end

  def test_encoder_failures_are_encoding_failures
    assert_equal :encoding, failure_code { fake_encoder("cat >/dev/null; exit 3").call(wav) }
    assert_equal :encoding, failure_code { fake_encoder("cat >/dev/null; printf 'RIFFnotogg'").call(wav) }
    assert_equal :encoding, failure_code { fake_encoder("cat >/dev/null; printf 'OggS-without-the-opus-header'").call(wav) }
    missing = PrismHubot::Speech::OpusEncoder.new(executable: "/nonexistent/opusenc")
    assert_equal :encoding, failure_code { missing.call(wav) }
  end

  def test_encoder_is_killed_when_it_runs_past_its_limit
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_equal :timeout, failure_code { fake_encoder("sleep 30", timeout: 0.3).call(wav) }
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5
  end

  def test_real_opusenc_makes_a_voice_clip_when_it_is_installed
    skip "opusenc is not installed" unless system("opusenc", "--version", out: File::NULL, err: File::NULL)

    clip = PrismHubot::Speech::Voice.new(
      synthesizer: ->(_text) { PrismHubot::Speech::Wav.parse(pcm16_wav(seconds: 2)) },
      encoder: PrismHubot::Speech::OpusEncoder.new
    ).call("текст")
    assert_kind_of PrismBot::Domain::VoiceClip, clip
    assert_equal 2, clip.duration_seconds
  end

  # --- Voice and configuration -----------------------------------------------------------------------

  def test_voice_wraps_the_encoded_audio_with_the_synthesized_duration
    voice = PrismHubot::Speech::Voice.new(synthesizer: ->(_text) { PrismHubot::Speech::Wav.parse(pcm16_wav(seconds: 5)) },
      encoder: ->(_wav) { ogg_opus })
    clip = voice.call("текст")
    assert_equal 5, clip.duration_seconds
    assert clip.audio.start_with?("OggS")
  end

  def test_voice_reports_audio_telegram_would_not_play_as_an_encoding_failure
    voice = PrismHubot::Speech::Voice.new(synthesizer: ->(_text) { PrismHubot::Speech::Wav.parse(pcm16_wav) },
      encoder: ->(_wav) { "not ogg" })
    assert_equal :encoding, failure_code { voice.call("текст") }
  end

  def environment(**overrides)
    {"PRISM_HUBOT_TTS_URL" => "https://tts.example.test/v1/speech", "PRISM_HUBOT_AIS_CLIENT_ID" => "prism-hubot",
     "PRISM_HUBOT_AIS_PRIVATE_KEY" => key.private_to_pem}.merge(overrides.transform_keys(&:to_s))
  end

  def test_speech_is_off_without_a_url_and_refuses_a_half_configuration
    assert_nil PrismHubot::Speech::Configuration.build({})
    assert_nil PrismHubot::Speech::Configuration.build({"PRISM_HUBOT_TTS_URL" => "  "})
    error = assert_raises(PrismBot::ConfigurationError) do
      PrismHubot::Speech::Configuration.build(environment(PRISM_HUBOT_AIS_PRIVATE_KEY: ""))
    end
    assert_includes error.message, "PRISM_HUBOT_AIS_PRIVATE_KEY"
    refute_includes error.message, key.private_to_pem[10, 20]
  end

  def test_speech_urls_must_be_https
    assert_raises(PrismBot::ConfigurationError) do
      PrismHubot::Speech::Configuration.build(environment(PRISM_HUBOT_TTS_URL: "http://tts.example.test/v1/speech"))
    end
    assert_raises(PrismBot::ConfigurationError) do
      PrismHubot::Speech::Configuration.build(environment(PRISM_HUBOT_AIS_TOKEN_URL: "http://auth.example.test/token"))
    end
  end

  def test_configured_speech_goes_from_text_to_a_voice_clip
    http = FakeHttp.new(token_response("tok-9"), Response.new(status: 200, body: pcm16_wav(seconds: 4)))
    voice = PrismHubot::Speech::Configuration.build(environment(PRISM_HUBOT_TTS_VOICE: "uk-UA"), http: http,
      encoder: ->(_wav) { ogg_opus })

    clip = voice.call("Ада: привіт")
    assert_equal 4, clip.duration_seconds
    assert_equal "https://auth.aiaiaiai.org/token", http.posts.fetch(0).fetch(:url)
    assert_equal "Bearer tok-9", http.posts.fetch(1).fetch(:headers).fetch("authorization")
    assert_equal "uk-UA", JSON.parse(http.posts.fetch(1).fetch(:body)).fetch("voice")
  end
end
