# © 2026 aiaiaiai · aiaiaiai.org

require_relative "test_helper"

class WhisperPickerTest < Minitest::Test
  include PrismHubotTestSupport

  CHAT = -1001
  USER = 7

  class Members
    def chat_membership(chat_id:, user_id:)
      PrismBot::Domain::ChatMembership.new(chat_id: chat_id, user_id: user_id, status: "administrator")
    end

    def own_membership(chat_id:)
      PrismBot::Domain::ChatMembership.new(chat_id: chat_id, user_id: 1, status: "administrator")
    end
  end

  def setup
    @now = 1_700_000_000
    @history = PrismHubot::Whisper::History.new(clock: -> { @now })
    @sender = MessageSender.new
    @private = EphemeralSender.new
    services = PrismHubotTestSupport.services(
      message_sender: @sender, publish_publication: PublishPublication.new, ephemeral_sender: @private,
      chat_members: Members.new
    )
    sessions = PrismHubot::Whisper::Sessions.new(clock: -> { @now })
    @composition = PrismHubot::Client.new(
      state_store: MemoryStateStore.new, history: @history, sessions: sessions,
      picker_view: PrismHubot::Whisper::PickerView.new(clock: -> { @now })
    ).call(services)
    @callbacks = PrismBot::Channels::Telegram::CallbackRouter.new(handlers: @composition.callback_handlers)
    @history.enable(chat_id: CHAT)
    @history.enable(chat_id: CHAT, topic_id: 5)
    # Nothing sent before Whisper was switched on is eligible, so time moves on first.
    @now += 7_200
  end

  def say(id, text, author: 1, name: "Ада", username: "ada", topic: nil, at: @now)
    @history.observe(chat_id: CHAT, topic_id: topic, id: id, revision: 1, timestamp: at, author_id: author,
      label: name, username: username, text: text)
  end

  def whisper(arguments = "", user: USER, thread: nil)
    @composition.command_handlers.fetch("whisper").call(
      update: private_update(text: "/whisper #{arguments}".strip, user_id: user, thread: thread), arguments: arguments
    )
  end

  def press(data, user: USER, thread: nil, source: 8)
    @callbacks.call(callback_update(data: data, user_id: user, thread: thread, source_ephemeral: source))
  end

  def listing
    @private.sent.last
  end

  def edited
    @private.edits.last
  end

  def test_lists_kept_messages_newest_first_privately_with_safe_snippets
    say(1, "перше\nповідомлення  з   пробілами", at: @now - 3_600 * 2)
    say(2, "друге", author: 2, name: "Борис", username: "boris", at: @now - 600)

    whisper

    text = listing[:text]
    assert text.start_with?(PrismHubot::Copy::PRIVATE)
    assert_operator text.index("Борис: друге"), :<, text.index("Ада: перше повідомлення з пробілами")
    assert_includes text, "10 хв тому"
    assert_includes text, "2 год тому"
    assert_includes text, "Сторінка 1/1."
    assert_equal %w[wp:s:2 wp:s:1 wp:x], listing[:reply_markup].rows.flatten.map(&:callback_data)
    assert_empty @sender.messages
  end

  def test_nothing_is_listed_when_nothing_was_kept
    whisper

    assert_equal ["#{PrismHubot::Copy::PRIVATE}\n#{PrismHubot::Copy::WHISPER_REFUSALS.fetch("history_unavailable")}"], @sender.messages.map { _1[:text] }
    assert_empty @private.sent
  end

  def test_author_filter_limit_and_screen_arguments
    say(1, "а", author: 1, username: "ada")
    say(2, "б", author: 2, name: "Борис", username: "boris")
    say(3, "в", author: 1, username: "ada")

    whisper("@ada")
    assert_equal %w[wp:s:3 wp:s:1 wp:x], listing[:reply_markup].rows.flatten.map(&:callback_data)
    whisper("@ada @boris 2")
    assert_equal %w[wp:s:3 wp:s:2 wp:x], listing[:reply_markup].rows.flatten.map(&:callback_data)
    whisper("екран")
    assert_equal 4, listing[:reply_markup].rows.length
  end

  def test_unknown_or_ambiguous_arguments_are_refused_without_guessing
    say(1, "а")
    ["що завгодно", "0", "51", "5 6", "екран екран", "@@x"].each do |arguments|
      @sender.messages.clear
      whisper(arguments)
      assert_equal [PrismHubot::Copy::WHISPER_USAGE], @sender.messages.map { _1[:text] }, arguments
    end
    @sender.messages.clear
    whisper("@nobody")
    assert_includes @sender.messages.fetch(0)[:text], PrismHubot::Copy::WHISPER_REFUSALS.fetch("unresolved_author")
  end

  def test_pages_of_five_with_navigation_that_edits_the_same_message
    (1..7).each { |id| say(id, "повідомлення #{id}", at: @now - 100 + id) }

    whisper
    assert_includes listing[:text], "Сторінка 1/2."
    assert_equal %w[wp:s:7 wp:s:6 wp:s:5 wp:s:4 wp:s:3 wp:p:2 wp:x], listing[:reply_markup].rows.flatten.map(&:callback_data)

    press("wp:p:2")
    assert_includes edited[:text], "Сторінка 2/2."
    assert_equal %w[wp:s:2 wp:s:1 wp:p:1 wp:x], edited[:reply_markup].rows.flatten.map(&:callback_data)
    assert_equal 8, edited[:ref].ephemeral_message_id
    press("wp:p:99")
    assert_includes edited[:text], "Сторінка 2/2."
  end

  def test_choosing_fixes_the_start_and_reports_the_size_of_the_range
    say(1, "один")
    say(2, "два")
    say(3, "три")
    whisper

    press("wp:s:2")

    assert_equal format(PrismHubot::Copy::WHISPER_CHOSEN, count: 2, characters: "Ада: два\nтри".length), edited[:text]
    assert_nil edited[:reply_markup]
  end

  def test_a_range_over_the_limit_is_refused_privately_not_truncated
    (1..60).each { |id| say(id, "x", at: @now - 100 + id) }
    @history.disable(chat_id: CHAT)
    @history.enable(chat_id: CHAT)
    (1..60).each { |id| say(id, "x", at: @now) }
    whisper

    press("wp:s:1")

    assert_includes edited[:text], PrismHubot::Copy::WHISPER_REFUSALS.fetch("range_limit")
  end

  def test_a_press_without_its_own_open_list_is_stale_and_other_people_cannot_reuse_a_list
    say(1, "а")
    press("wp:s:1")
    assert_equal PrismHubot::Copy::WHISPER_PICKER_STALE, edited[:text]

    whisper
    press("wp:s:1", user: 8)
    assert_equal PrismHubot::Copy::WHISPER_PICKER_STALE, edited[:text]
  end

  def test_an_edit_or_new_state_makes_the_list_stale
    say(1, "а")
    whisper
    @history.observe(chat_id: CHAT, id: 1, revision: 2, timestamp: @now, author_id: 1, label: "Ада", username: "ada", text: "змінено")

    press("wp:p:1")

    assert_includes edited[:text], PrismHubot::Copy::WHISPER_REFUSALS.fetch("stale_snapshot")
  end

  def test_a_list_expires_and_cancel_closes_it
    say(1, "а")
    whisper
    press("wp:x")
    assert_equal PrismHubot::Copy::WHISPER_PICKER_CLOSED, edited[:text]
    press("wp:p:1")
    assert_equal PrismHubot::Copy::WHISPER_PICKER_STALE, edited[:text]

    whisper
    @now += PrismHubot::Whisper::History::MAX_SNAPSHOT_AGE + 1
    press("wp:s:1")
    assert_equal PrismHubot::Copy::WHISPER_PICKER_STALE, edited[:text]
  end

  def test_malformed_press_data_is_ignored
    say(1, "а")
    whisper
    before = @private.edits.length

    ["wp", "wp:", "wp:p", "wp:p:x", "wp:p:0", "wp:s:-1", "wp:s:1:2", "wp:x:1", "wp:z:1", "wp:s: 1"].each { |data| press(data) }

    assert_equal before, @private.edits.length
  end

  def test_topics_have_separate_lists
    say(1, "у корені")
    say(2, "у темі", topic: 5)

    whisper("", thread: 5)

    assert_includes listing[:text], "у темі"
    refute_includes listing[:text], "у корені"
    assert_equal 5, listing[:target].message_thread_id
  end

  def test_everything_shown_is_private_and_a_public_command_reveals_no_content
    say(1, "таємниця")
    @composition.command_handlers.fetch("whisper").call(
      update: authorized_update(text: "/whisper", update_id: 1, chat_id: CHAT, chat_type: "supergroup"), arguments: ""
    )

    assert_equal [PrismHubot::Copy::WHISPER_PUBLIC_HINT], @sender.messages.map { _1[:text] }
    refute @sender.messages.any? { _1[:text].include?("таємниця") }
    whisper
    assert listing[:text].start_with?(PrismHubot::Copy::PRIVATE)
  end

  def test_sessions_are_bounded_and_hide_their_content
    sessions = PrismHubot::Whisper::Sessions.new(clock: -> { @now })
    say(1, "а")
    snapshot = @history.snapshot(chat_id: CHAT, actor: 1)

    (PrismHubot::Whisper::Sessions::MAX_SESSIONS + 5).times do |index|
      sessions.open(chat_id: CHAT, topic_id: nil, user_id: index + 1, snapshot: snapshot)
    end

    assert_nil sessions.fetch(chat_id: CHAT, topic_id: nil, user_id: 1)
    assert sessions.fetch(chat_id: CHAT, topic_id: nil, user_id: PrismHubot::Whisper::Sessions::MAX_SESSIONS + 5)
    assert_equal "#<Whisper::Session redacted>", sessions.fetch(chat_id: CHAT, topic_id: nil, user_id: 205).inspect
    assert_equal "#<Whisper::Sessions redacted>", sessions.inspect
  end
end
