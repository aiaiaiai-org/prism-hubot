# © 2026 aiaiaiai · aiaiaiai.org

require_relative "test_helper"

# Choosing a range in the Whisper picker turns it into a private voice message in the background.
class WhisperSpeakerTest < Minitest::Test
  include PrismHubotTestSupport

  CHAT = -1001
  USER = 7
  PRIVATE = PrismHubot::Copy::PRIVATE

  class Members
    def chat_membership(chat_id:, user_id:)
      PrismBot::Domain::ChatMembership.new(chat_id: chat_id, user_id: user_id, status: "administrator")
    end

    def own_membership(chat_id:)
      PrismBot::Domain::ChatMembership.new(chat_id: chat_id, user_id: 1, status: "administrator")
    end
  end

  # Runs a job as soon as it is posted, or holds it until #drain, or refuses it when full.
  class Executor
    attr_reader :jobs

    def initialize(mode: :inline)
      @mode = mode
      @jobs = []
    end

    def post(&job)
      case @mode
      when :inline then job.call
      when :hold then @jobs << job
      when :full then return false
      end
      true
    end

    def drain
      @jobs.shift.call until @jobs.empty?
    end
  end

  class Voice
    attr_reader :texts

    def initialize(result: nil, error: nil)
      @result = result || PrismBot::Domain::VoiceClip.new(audio: "OggS".b + "\0" * 20 + "OpusHead".b + "\1" * 10,
        duration_seconds: 3)
      @error = error
      @texts = []
    end

    def call(text)
      @texts << text
      raise @error if @error

      @result
    end
  end

  class Log
    attr_reader :lines

    def initialize
      @lines = []
    end

    def warn(message)
      @lines << message
    end
    alias_method :error, :warn
  end

  def setup
    @now = 1_700_000_000
    @history = PrismHubot::Whisper::History.new(clock: -> { @now })
    @sender = MessageSender.new
    @private = EphemeralSender.new
    @log = Log.new
    @history.enable(chat_id: CHAT)
    @now += 7_200
  end

  def build(voice: Voice.new, executor: Executor.new)
    @voice = voice
    @executor = executor
    services = PrismHubotTestSupport.services(
      message_sender: @sender, publish_publication: PublishPublication.new, ephemeral_sender: @private,
      chat_members: Members.new
    )
    composition = PrismHubot::Client.new(
      state_store: MemoryStateStore.new, history: @history, sessions: PrismHubot::Whisper::Sessions.new(clock: -> { @now }),
      picker_view: PrismHubot::Whisper::PickerView.new(clock: -> { @now }),
      speech: voice, executor: executor, logger: @log
    ).call(services)
    @composition = composition
    @callbacks = PrismBot::Channels::Telegram::CallbackRouter.new(handlers: composition.callback_handlers)
  end

  def say(id, text, author: 1, name: "Ада", username: "ada")
    @history.observe(chat_id: CHAT, topic_id: nil, id: id, revision: 1, timestamp: @now, author_id: author,
      label: name, username: username, text: text)
  end

  def choose(anchor, user: USER, source: 8)
    @composition.command_handlers.fetch("whisper").call(update: private_update(text: "/whisper", user_id: user), arguments: "")
    @callbacks.call(callback_update(data: "wp:s:#{anchor}", user_id: user, source_ephemeral: source))
  end

  def statuses
    @private.edits.map { _1[:text] }
  end

  def public_texts
    @sender.messages.map { _1[:text] }
  end

  def test_the_chosen_range_is_spoken_and_sent_only_to_the_person
    build
    say(1, "один")
    say(2, "два")

    choose(1)

    assert_equal ["Ада: один\nдва"], @voice.texts
    assert_equal 1, @private.voices.length
    sent = @private.voices.fetch(0)
    assert_equal PRIVATE, sent[:caption]
    assert_equal :member, sent[:target].mode
    assert_equal [CHAT, USER], [sent[:target].chat_id, sent[:target].receiver_user_id]
    assert_equal 3, sent[:clip].duration_seconds
    assert_empty public_texts, "nothing about the voice reaches the group"
    refute(@private.voices.any? { _1.key?(:message_thread_id) && !_1.key?(:target) }, "no public voice")
  end

  def test_one_status_message_goes_from_working_to_done
    build
    say(1, "один")

    choose(1)

    assert_equal [format(PrismHubot::Copy::WHISPER_CHOSEN_SPEAKING, count: 1, characters: "Ада: один".length),
      PrismHubot::Copy::WHISPER_VOICE_DONE], statuses
    assert_equal [8, 8], @private.edits.map { _1[:ref].ephemeral_message_id }
    assert(statuses.all? { _1.start_with?(PRIVATE) })
  end

  def test_the_working_status_is_set_before_the_work_can_finish
    build(executor: Executor.new(mode: :hold))
    say(1, "один")

    choose(1)
    assert_equal 1, statuses.length
    assert_includes statuses.last, "Озвучую"

    @executor.drain
    assert_equal PrismHubot::Copy::WHISPER_VOICE_DONE, statuses.last
  end

  def test_every_speech_failure_is_told_privately_and_sends_no_voice
    PrismHubot::Speech::Failure::CODES.each do |code|
      @private = EphemeralSender.new
      @sender = MessageSender.new
      @log = Log.new
      build(voice: Voice.new(error: PrismHubot::Speech::Failure.new(code)))
      say(1, "один")

      choose(1)

      assert_equal PrismHubot::Copy::WHISPER_SPEECH_FAILURES.fetch(code), statuses.last, code.to_s
      assert_empty @private.voices
      assert_empty public_texts
      assert_equal ["whisper_speech failed code=#{code}"], @log.lines
    end
  end

  def test_a_voice_telegram_refuses_to_deliver_privately_is_never_made_public
    build
    @private.define_singleton_method(:send_ephemeral_voice) do |**|
      raise PrismBot::MessageDeliveryError.new("bot.telegram.ephemeral.unconfirmed", "Telegram did not confirm private delivery")
    end
    say(1, "один")

    choose(1)

    assert_equal PrismHubot::Copy::WHISPER_VOICE_NOT_DELIVERED, statuses.last
    assert_empty public_texts
    assert_equal ["whisper_speech not_delivered code=bot.telegram.ephemeral.unconfirmed"], @log.lines
  end

  def test_an_unexpected_error_is_logged_without_its_message_and_told_privately
    build(voice: Voice.new(error: RuntimeError.new("секретний текст повідомлення")))
    say(1, "один")

    choose(1)

    assert_equal PrismHubot::Copy::WHISPER_REFUSAL_FALLBACK, statuses.last
    assert_equal ["whisper_speech unexpected_error class=RuntimeError"], @log.lines
    refute(@log.lines.any? { _1.include?("секретний") })
    assert_empty public_texts
  end

  def test_a_failing_status_edit_neither_raises_nor_goes_public
    build
    calls = 0
    @private.define_singleton_method(:edit_ephemeral_message) do |ref:, text:, reply_markup: nil|
      calls += 1
      raise PrismBot::MessageDeliveryError.new("bot.telegram.unavailable", "Telegram is unavailable") if calls > 1

      @edits << {ref: ref, text: text, reply_markup: reply_markup}
      nil
    end
    say(1, "один")

    choose(1)

    assert_equal 1, @private.voices.length
    assert_empty public_texts
    assert_includes @log.lines, "whisper_speech status_not_updated code=bot.telegram.unavailable"
  end

  def test_a_person_has_one_voice_in_progress_at_a_time
    build(executor: Executor.new(mode: :hold))
    say(1, "один")
    say(2, "два")

    choose(1)
    choose(2)

    assert_equal PrismHubot::Copy::WHISPER_VOICE_BUSY, statuses.last
    assert_equal 1, @executor.jobs.length

    @executor.drain
    choose(2)
    assert_includes statuses.last, "Озвучую"
    @executor.drain
    assert_equal 2, @private.voices.length
  end

  def test_the_slot_is_released_even_when_the_work_fails
    build(voice: Voice.new(error: PrismHubot::Speech::Failure.new(:timeout)))
    say(1, "один")

    2.times { choose(1) }

    assert_equal 2, @voice.texts.length
  end

  def test_other_people_are_not_blocked_by_someone_in_progress
    build(executor: Executor.new(mode: :hold))
    say(1, "один")

    choose(1, user: 7)
    choose(1, user: 8)

    assert_equal 2, @executor.jobs.length
  end

  def test_a_full_pool_says_busy_and_leaves_no_slot_taken
    build(executor: Executor.new(mode: :full))
    say(1, "один")

    choose(1)
    assert_equal PrismHubot::Copy::WHISPER_VOICE_BUSY, statuses.last

    @executor.instance_variable_set(:@mode, :inline)
    choose(1)
    assert_equal PrismHubot::Copy::WHISPER_VOICE_DONE, statuses.last
  end

  def test_without_speech_the_range_is_chosen_and_voice_is_said_to_be_unavailable
    build(voice: nil)
    say(1, "один")

    choose(1)

    assert_equal [format(PrismHubot::Copy::WHISPER_CHOSEN, count: 1, characters: "Ада: один".length)], statuses
    assert_includes statuses.last, "Озвучення поки недоступне"
    assert_empty @private.voices
  end

  def test_a_status_with_no_private_message_to_edit_is_dropped_never_posted_to_the_group
    responder = PrismHubot::Whisper::Responder.new(message_sender: @sender, ephemeral_sender: @private)
    update = callback_update(data: "wp:s:1", source_ephemeral: nil) # pressed on a public message: no ref
    speaker = PrismHubot::Whisper::Speaker.new(voice: Voice.new, voice_sender: @private, responder: responder,
      executor: Executor.new, logger: @log)

    assert_nil responder.settle_private(update, "статус")
    speaker.start(update, "текст")

    assert_equal 1, @private.voices.length
    assert_empty @private.edits
    assert_empty public_texts
  end

  def test_the_real_thread_pool_runs_jobs_off_the_calling_thread_and_is_bounded
    done = Queue.new
    caller_thread = Thread.current
    executor = PrismHubot::Whisper::ThreadExecutor.new(workers: 1, capacity: 1)
    gate = Queue.new

    assert executor.post { gate.pop } # taken by the one worker, which then waits on the gate
    sleep 0.05
    assert executor.post { done << Thread.current } # waits in the queue of one
    refute executor.post { nil }, "a full queue refuses"
    gate << :go
    refute_equal caller_thread, done.pop
  end
end
