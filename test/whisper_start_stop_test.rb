# © 2026 aiaiaiai · aiaiaiai.org

require_relative "test_helper"

class WhisperStartStopTest < Minitest::Test
  include PrismHubotTestSupport

  CHAT = -1001
  ADMIN = 7
  MEMBER = 8

  class Members
    def initialize(statuses: {ADMIN => "administrator"}, own: "administrator", error: nil)
      @statuses = statuses
      @own = own
      @error = error
    end

    def chat_membership(chat_id:, user_id:)
      raise @error if @error

      PrismBot::Domain::ChatMembership.new(chat_id: chat_id, user_id: user_id, status: @statuses.fetch(user_id, "member"))
    end

    def own_membership(chat_id:)
      raise @error if @error

      PrismBot::Domain::ChatMembership.new(chat_id: chat_id, user_id: 1, status: @own)
    end
  end

  class FailingAnnouncer < MessageSender
    def send_message(**arguments)
      raise PrismBot::MessageDeliveryError.new("bot.telegram.send_failed", "no") unless arguments[:ephemeral]

      super
    end
  end

  def setup
    @now = 1_700_000_100
    @history = PrismHubot::Whisper::History.new(clock: -> { @now })
    build
  end

  def build(members: Members.new, sender: MessageSender.new)
    @sender = sender
    @private = EphemeralSender.new
    services = PrismHubotTestSupport.services(
      message_sender: @sender, publish_publication: PublishPublication.new,
      ephemeral_sender: @private, chat_members: members
    )
    @composition = PrismHubot::Client.new(state_store: MemoryStateStore.new, history: @history, sessions: PrismHubot::Whisper::Sessions.new(clock: -> { @now })).call(services)
  end

  def start(user: ADMIN, thread: nil)
    command("start", private_update(text: "/start", user_id: user, thread: thread))
  end

  def command(name, update)
    @composition.command_handlers.fetch(name).call(update: update, arguments: "")
  end

  def status(thread: nil)
    @history.status(chat_id: CHAT, topic_id: thread)
  end

  def private_texts
    @private.sent.map { _1[:text] } + @private.edits.map { _1[:text] } + @sender.messages.select { _1[:ephemeral] }.map { _1[:text] }
  end

  def public_messages
    @sender.messages.reject { _1[:ephemeral] }
  end

  def test_the_client_has_exactly_the_four_commands_and_all_of_them_are_open
    assert_equal %w[start stop whisper whisper_private], @composition.command_handlers.keys.sort
    assert_equal %w[start stop whisper whisper_private], @composition.open_commands.sort
    assert_equal ["wp"], @composition.callback_handlers.keys
  end

  def test_an_ordinary_group_message_gets_only_a_public_hint_with_no_content
    %w[start stop whisper whisper_private].each do |name|
      @sender.messages.clear
      command(name, authorized_update(text: "/#{name}", update_id: 1, chat_id: CHAT, chat_type: "supergroup"))

      assert_equal [PrismHubot::Copy::WHISPER_PUBLIC_HINT], public_messages.map { _1[:text] }, name
    end
    assert_empty private_texts
    assert_equal :not_enabled, status
  end

  def test_in_a_private_chat_the_commands_explain_that_whisper_reads_groups
    %w[start stop whisper whisper_private].each do |name|
      @sender.messages.clear
      command(name, authorized_update(text: "/#{name}", update_id: 1, chat_id: 77, chat_type: "private"))

      assert_equal [PrismHubot::Copy::WHISPER_NOT_A_GROUP], @sender.messages.map { _1[:text] }, name
    end
  end

  def test_an_administrator_start_announces_to_the_group_first_then_enables_and_tells_them_privately
    start(thread: 5)

    announcement = public_messages.fetch(0)
    assert_equal [CHAT, 5, PrismHubot::Copy::WHISPER_ANNOUNCE_ON], [announcement[:chat_id], announcement[:message_thread_id], announcement[:text]]
    assert_equal :enabled, status(thread: 5)
    private_reply = @sender.messages.select { _1[:ephemeral] }.fetch(0)
    assert_equal PrismHubot::Copy::WHISPER_ENABLED, private_reply[:text]
    assert_equal :not_enabled, status
    assert_equal :not_enabled, status(thread: 6)
  end

  def test_the_creator_may_start_too
    build(members: Members.new(statuses: {MEMBER => "creator"}))

    start(user: MEMBER)

    assert_equal :enabled, status
  end

  def test_members_cannot_start_or_stop_whisper
    start(user: MEMBER)
    assert_equal :not_enabled, status
    assert_empty public_messages
    assert_equal [PrismHubot::Copy::WHISPER_NOT_ADMIN], @sender.messages.map { _1[:text] }

    @history.enable(chat_id: CHAT)
    @sender.messages.clear
    command("stop", private_update(text: "/stop", user_id: MEMBER))
    assert_equal :enabled, status
    assert_equal [PrismHubot::Copy::WHISPER_NOT_ADMIN], @sender.messages.map { _1[:text] }
  end

  def test_the_bot_must_itself_be_an_administrator_and_an_unconfirmed_lookup_is_never_permission
    build(members: Members.new(own: "member"))
    start
    assert_equal [PrismHubot::Copy::WHISPER_BOT_NOT_ADMIN], @sender.messages.map { _1[:text] }
    assert_equal :not_enabled, status

    build(members: Members.new(error: PrismBot::MessageDeliveryError.new("bot.telegram.chat_member.failed", "no")))
    start
    assert_equal [PrismHubot::Copy::WHISPER_UNCONFIRMED], @sender.messages.map { _1[:text] }
    assert_equal :not_enabled, status
    assert_empty public_messages
  end

  def test_if_the_group_cannot_be_told_nothing_is_switched_on
    build(sender: FailingAnnouncer.new)

    start

    assert_equal :not_enabled, status
    assert_equal [PrismHubot::Copy::WHISPER_NOT_DISCLOSED], @sender.messages.select { _1[:ephemeral] }.map { _1[:text] }
  end

  def test_starting_twice_changes_nothing_and_announces_once
    start
    @sender.messages.clear

    start

    assert_empty public_messages
    assert_equal [PrismHubot::Copy::WHISPER_ALREADY_ON], @sender.messages.map { _1[:text] }
    assert_equal :enabled, status
  end

  def test_whisper_before_start_says_only_an_administrator_can_start_it
    %w[whisper whisper_private].each do |name|
      @sender.messages.clear
      command(name, private_update(text: "/#{name}", user_id: MEMBER))

      assert_equal [PrismHubot::Copy::WHISPER_NOT_ENABLED], @sender.messages.map { _1[:text] }, name
      assert_empty @private.sent
    end
    assert_includes PrismHubot::Copy::WHISPER_NOT_ENABLED, "/start"
  end

  def test_when_enabled_whisper_collects_group_messages_for_the_picker
    start
    observe(id: 301, text: "Привіт усім")
    observe(id: 302, text: "/help", command: true)

    snapshot = @history.snapshot(chat_id: CHAT, actor: 9)

    assert_equal [[301, 1]], snapshot.references
  end

  def test_group_messages_are_not_kept_until_an_administrator_enables_whisper
    refute observe(id: 301, text: "до дозволу")

    start

    assert_raises(PrismHubot::Whisper::Refusal) { @history.snapshot(chat_id: CHAT, actor: 9) }
  end

  def test_an_edit_replaces_the_text_and_orders_after_the_original
    start
    assert observe(id: 301, text: "перше")
    assert observe(id: 301, text: "виправлене", edited: true, update_id: 120)
    refute observe(id: 301, text: "старе", edited: true, update_id: 110)

    snapshot = @history.snapshot(chat_id: CHAT, actor: 9)
    texts = @history.select(snapshot, chat_id: CHAT, actor: 9, anchor: 301).map(&:text)
    assert_equal ["виправлене"], texts
  end

  def test_an_unclean_display_name_becomes_a_safe_spoken_label
    start
    observe(id: 301, text: "x", display_name: "Ада\n‮ Лавлейс​")
    observe(id: 302, text: "y", display_name: "", username: "ghost", author_id: 9)
    observe(id: 303, text: "z", display_name: " \n ", username: nil, author_id: 10)

    snapshot = @history.snapshot(chat_id: CHAT, actor: 9)
    labels = @history.select(snapshot, chat_id: CHAT, actor: 9, anchor: 301).map(&:label)
    assert_equal ["Ада Лавлейс", "ghost", "Учасник"], labels
  end

  def test_stop_stops_collection_clears_history_and_tells_the_group
    start
    observe(id: 301, text: "буде забуто")
    @sender.messages.clear
    @private.edits.clear

    command("stop", private_update(text: "/stop"))

    assert_equal :not_enabled, status
    refute observe(id: 302, text: "вже не зберігається")
    assert_equal [PrismHubot::Copy::WHISPER_ANNOUNCE_OFF], public_messages.map { _1[:text] }
    assert_equal [PrismHubot::Copy::WHISPER_DISABLED], @sender.messages.select { _1[:ephemeral] }.map { _1[:text] }
    assert_raises(PrismHubot::Whisper::Refusal) { @history.snapshot(chat_id: CHAT, actor: 9) }
  end

  def test_stop_refuses_non_administrators_and_reports_when_already_off
    start
    @sender.messages.clear

    command("stop", private_update(text: "/stop", user_id: MEMBER))
    assert_equal :enabled, status
    assert_equal [PrismHubot::Copy::WHISPER_NOT_ADMIN], @sender.messages.map { _1[:text] }

    @history.disable(chat_id: CHAT)
    @sender.messages.clear
    command("stop", private_update(text: "/stop"))
    assert_equal [PrismHubot::Copy::WHISPER_ALREADY_OFF], @sender.messages.map { _1[:text] }
    assert_empty public_messages
  end

  def test_stop_in_a_public_message_only_hints
    command("stop", authorized_update(text: "/stop", update_id: 1, chat_id: CHAT, chat_type: "supergroup"))

    assert_equal [PrismHubot::Copy::WHISPER_PUBLIC_HINT], public_messages.map { _1[:text] }
  end

  def test_every_private_message_states_its_audience_and_no_public_one_claims_to_be_private
    command("whisper", private_update(text: "/whisper", user_id: MEMBER))
    command("start", private_update(text: "/start", user_id: MEMBER))
    start
    start
    command("stop", private_update(text: "/stop", user_id: MEMBER))
    command("stop", private_update(text: "/stop"))
    command("stop", private_update(text: "/stop"))

    refute_empty private_texts
    private_texts.each { |text| assert text.start_with?(PrismHubot::Copy::PRIVATE), text }
    public_messages.each { |message| refute_includes message[:text], "Приватно" }
  end

  def test_history_reports_its_status_without_content
    assert_equal :not_enabled, @history.status(chat_id: CHAT)
    @history.enable(chat_id: CHAT)
    assert_equal :enabled, @history.status(chat_id: CHAT)
    @history.disable(chat_id: CHAT)
    assert_equal :not_enabled, @history.status(chat_id: CHAT)
    assert_raises(PrismHubot::Whisper::Refusal) { @history.status(chat_id: 0) }
  end

  private

  def observe(id:, text:, command: false, edited: false, update_id: 100, display_name: "Ада", username: "ada", author_id: 7)
    surface = PrismBot::Channels::Telegram::SurfaceContext.new(chat_id: CHAT, chat_type: "supergroup")
    observation = PrismBot::Channels::Telegram::Observation.new(
      update_id: update_id, surface_context: surface, message_id: id, author_id: author_id,
      text: command ? "/help" : text, sent_at: @now, display_name: display_name, username: username, edited: edited
    )
    @composition.observers.map { _1.call(observation) }.last
  end
end
