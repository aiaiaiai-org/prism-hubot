# © 2026 aiaiaiai · aiaiaiai.org

require_relative "test_helper"

class WhisperActivationTest < Minitest::Test
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
    @composition = PrismHubot::Client.new(state_store: MemoryStateStore.new, history: @history).call(services)
    @callbacks = PrismBot::Channels::Telegram::CallbackRouter.new(handlers: @composition.callback_handlers)
  end

  def command(name, update)
    @composition.command_handlers.fetch(name).call(update: update, arguments: "")
  end

  def press(update)
    @callbacks.call(update)
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

  def test_an_ordinary_group_message_gets_only_a_public_hint_with_no_content
    update = authorized_update(text: "/whisper", update_id: 1, chat_id: CHAT, chat_type: "supergroup")

    command("whisper", update)

    assert_equal [PrismHubot::Copy::WHISPER_PUBLIC_HINT], public_messages.map { _1[:text] }
    assert_empty private_texts
    assert_equal :not_enabled, status
  end

  def test_in_a_private_chat_whisper_explains_it_reads_groups
    update = authorized_update(text: "/whisper", update_id: 1, chat_id: 77, chat_type: "private")

    command("whisper", update)

    assert_equal [PrismHubot::Copy::WHISPER_NOT_A_GROUP], @sender.messages.map { _1[:text] }
  end

  def test_an_administrator_is_offered_consent_buttons_with_the_disclosure
    command("whisper", private_update(text: "/whisper", thread: 5))

    offer = @private.sent.fetch(0)
    assert_equal PrismHubot::Copy::WHISPER_ENABLE_DISCLOSURE, offer[:text]
    assert_equal %w[wa:on wa:no], offer[:reply_markup].rows.flatten.map(&:callback_data)
    assert_equal [CHAT, 5, ADMIN], [offer[:target].chat_id, offer[:target].message_thread_id, offer[:target].receiver_user_id]
    assert_empty @sender.messages
    assert_equal :not_enabled, status(thread: 5)
  end

  def test_others_are_told_why_they_cannot_enable_it
    command("whisper", private_update(text: "/whisper", user_id: MEMBER))
    assert_equal [PrismHubot::Copy::WHISPER_NOT_ENABLED], @sender.messages.map { _1[:text] }
    assert_empty @private.sent

    build(members: Members.new(own: "member"))
    command("whisper", private_update(text: "/whisper"))
    assert_equal [PrismHubot::Copy::WHISPER_BOT_NOT_ADMIN], @sender.messages.map { _1[:text] }

    build(members: Members.new(error: PrismBot::MessageDeliveryError.new("bot.telegram.chat_member.failed", "no")))
    command("whisper", private_update(text: "/whisper"))
    assert_equal [PrismHubot::Copy::WHISPER_UNCONFIRMED], @sender.messages.map { _1[:text] }
    assert_empty @private.sent
  end

  def test_pressing_enable_announces_to_the_group_first_then_enables_and_settles_privately
    press(callback_update(data: "wa:on", thread: 5))

    announcement = public_messages.fetch(0)
    assert_equal [CHAT, 5, PrismHubot::Copy::WHISPER_ANNOUNCE_ON], [announcement[:chat_id], announcement[:message_thread_id], announcement[:text]]
    assert_equal :enabled, status(thread: 5)
    assert_equal [PrismHubot::Copy::WHISPER_ENABLED], @private.edits.map { _1[:text] }
    assert_equal 8, @private.edits.fetch(0)[:ref].ephemeral_message_id
    assert_equal :not_enabled, status
    assert_equal :not_enabled, status(thread: 6)
  end

  def test_the_press_is_checked_for_authority_not_trusted
    press(callback_update(data: "wa:on", user_id: MEMBER))

    assert_equal :not_enabled, status
    assert_empty public_messages
    assert_equal [PrismHubot::Copy::WHISPER_NOT_ADMIN], @private.edits.map { _1[:text] }
  end

  def test_if_the_group_cannot_be_told_nothing_is_switched_on
    build(sender: FailingAnnouncer.new)

    press(callback_update(data: "wa:on"))

    assert_equal :not_enabled, status
    assert_equal [PrismHubot::Copy::WHISPER_NOT_DISCLOSED], @private.edits.map { _1[:text] }
  end

  def test_cancel_changes_nothing_and_unknown_payloads_are_ignored
    press(callback_update(data: "wa:no"))
    press(callback_update(data: "wa:whatever"))
    press(callback_update(data: "wa"))

    assert_equal :not_enabled, status
    assert_empty public_messages
    assert_equal [PrismHubot::Copy::WHISPER_CANCELLED], @private.edits.map { _1[:text] }
  end

  def test_a_press_on_a_public_button_settles_with_a_new_private_message
    press(callback_update(data: "wa:no", source_ephemeral: nil))

    assert_empty @private.edits
    assert_equal [PrismHubot::Copy::WHISPER_CANCELLED], @sender.messages.select { _1[:ephemeral] }.map { _1[:text] }
    assert_equal :callback, @sender.messages.fetch(0)[:ephemeral].mode
  end

  def test_when_enabled_whisper_reports_ready_and_collects_group_messages
    press(callback_update(data: "wa:on"))
    @sender.messages.clear
    observe(id: 301, text: "Привіт усім")
    observe(id: 302, text: "/help", command: true)

    command("whisper", private_update(text: "/whisper"))

    assert_equal [PrismHubot::Copy::WHISPER_READY], @sender.messages.map { _1[:text] }
    snapshot = @history.snapshot(chat_id: CHAT, actor: 9)
    assert_equal [[301, 1]], snapshot.references
  end

  def test_group_messages_are_not_kept_until_an_administrator_enables_whisper
    refute observe(id: 301, text: "до дозволу")

    press(callback_update(data: "wa:on"))

    assert_raises(PrismHubot::Whisper::Refusal) { @history.snapshot(chat_id: CHAT, actor: 9) }
  end

  def test_an_edit_replaces_the_text_and_orders_after_the_original
    press(callback_update(data: "wa:on"))
    assert observe(id: 301, text: "перше")
    assert observe(id: 301, text: "виправлене", edited: true, update_id: 120)
    refute observe(id: 301, text: "старе", edited: true, update_id: 110)

    snapshot = @history.snapshot(chat_id: CHAT, actor: 9)
    texts = @history.select(snapshot, chat_id: CHAT, actor: 9, anchor: 301).map(&:text)
    assert_equal ["виправлене"], texts
  end

  def test_an_unclean_display_name_becomes_a_safe_spoken_label
    press(callback_update(data: "wa:on"))
    observe(id: 301, text: "x", display_name: "Ада\n‮ Лавлейс​")
    observe(id: 302, text: "y", display_name: "", username: "ghost", author_id: 9)
    observe(id: 303, text: "z", display_name: " \n ", username: nil, author_id: 10)

    snapshot = @history.snapshot(chat_id: CHAT, actor: 9)
    labels = @history.select(snapshot, chat_id: CHAT, actor: 9, anchor: 301).map(&:label)
    assert_equal ["Ада Лавлейс", "ghost", "Учасник"], labels
  end

  def test_whisper_off_stops_collection_clears_history_and_tells_the_group
    press(callback_update(data: "wa:on"))
    observe(id: 301, text: "буде забуто")
    @sender.messages.clear
    @private.edits.clear

    command("whisper_off", private_update(text: "/whisper_off"))

    assert_equal :not_enabled, status
    refute observe(id: 302, text: "вже не зберігається")
    assert_equal [PrismHubot::Copy::WHISPER_ANNOUNCE_OFF], public_messages.map { _1[:text] }
    assert_equal [PrismHubot::Copy::WHISPER_DISABLED], @sender.messages.select { _1[:ephemeral] }.map { _1[:text] }
    assert_raises(PrismHubot::Whisper::Refusal) { @history.snapshot(chat_id: CHAT, actor: 9) }
  end

  def test_whisper_off_refuses_non_administrators_and_reports_when_already_off
    press(callback_update(data: "wa:on"))
    @sender.messages.clear

    command("whisper_off", private_update(text: "/whisper_off", user_id: MEMBER))
    assert_equal :enabled, status
    assert_equal [PrismHubot::Copy::WHISPER_NOT_ADMIN], @sender.messages.map { _1[:text] }

    @history.disable(chat_id: CHAT)
    @sender.messages.clear
    command("whisper_off", private_update(text: "/whisper_off"))
    assert_equal [PrismHubot::Copy::WHISPER_ALREADY_OFF], @sender.messages.map { _1[:text] }
    assert_empty public_messages
  end

  def test_whisper_off_in_a_public_message_only_hints
    command("whisper_off", authorized_update(text: "/whisper_off", update_id: 1, chat_id: CHAT, chat_type: "supergroup"))

    assert_equal [PrismHubot::Copy::WHISPER_PUBLIC_HINT], public_messages.map { _1[:text] }
  end

  def test_every_private_message_states_its_audience_and_no_public_one_claims_to_be_private
    command("whisper", private_update(text: "/whisper"))
    command("whisper", private_update(text: "/whisper", user_id: MEMBER))
    press(callback_update(data: "wa:on"))
    press(callback_update(data: "wa:no", user_id: MEMBER))
    command("whisper", private_update(text: "/whisper"))
    command("whisper_off", private_update(text: "/whisper_off"))

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
