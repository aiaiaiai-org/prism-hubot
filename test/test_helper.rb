# © 2026 aiaiaiai · aiaiaiai.org

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/prism_hubot"

module PrismHubotTestSupport
  class MemoryStateStore
    attr_reader :values

    def initialize
      @values = {}
    end

    def load(key:)
      @values[key]
    end

    def store(key:, state:)
      @values[key] = state
    end

    def delete(key:)
      @values.delete(key)
    end
  end

  class FakeOutboundDelivery
    attr_reader :calls

    def initialize(result: nil, error: nil)
      @result = result
      @error = error
      @calls = []
    end

    def deliver_message(chat_id:, text:, idempotency_key:, message_thread_id: nil)
      @calls << {
        chat_id: chat_id,
        text: text,
        idempotency_key: idempotency_key,
        message_thread_id: message_thread_id
      }
      raise @error if @error

      @result || PrismBot::Domain::DeliveryResult.new(
        provider_message_id: 42,
        idempotency_key: idempotency_key
      )
    end
  end

  # Records private (ephemeral) sends, edits and voice deliveries.
  class EphemeralSender
    attr_reader :sent, :edits, :voices

    def initialize
      @sent = []
      @edits = []
      @voices = []
    end

    def send_ephemeral_message(target:, text:, reply_markup: nil)
      @sent << {target: target, text: text, reply_markup: reply_markup}
      PrismBot::Domain::EphemeralMessageRef.new(
        chat_id: target.chat_id, receiver_user_id: target.receiver_user_id, ephemeral_message_id: @sent.length
      )
    end

    def edit_ephemeral_message(ref:, text:, reply_markup: nil)
      @edits << {ref: ref, text: text, reply_markup: reply_markup}
      nil
    end

    def send_ephemeral_voice(target:, clip:, caption:)
      @voices << {target: target, clip: clip, caption: caption}
      ref = PrismBot::Domain::EphemeralMessageRef.new(
        chat_id: target.chat_id, receiver_user_id: target.receiver_user_id, ephemeral_message_id: 900 + @voices.length
      )
      PrismBot::Domain::VoiceReceipt.new(file_id: "voice-file", ephemeral_ref: ref)
    end

    def send_public_voice(chat_id:, clip:, caption:, message_thread_id: nil)
      @voices << {chat_id: chat_id, message_thread_id: message_thread_id, clip: clip, caption: caption}
      PrismBot::Domain::VoiceReceipt.new(file_id: "voice-file", message_id: 700 + @voices.length)
    end
  end

  class ChatMemberLookup
    def initialize(statuses: {}, own: "administrator")
      @statuses = statuses
      @own = own
    end

    def chat_membership(chat_id:, user_id:)
      PrismBot::Domain::ChatMembership.new(chat_id: chat_id, user_id: user_id, status: @statuses.fetch(user_id, "member"))
    end

    def own_membership(chat_id:)
      PrismBot::Domain::ChatMembership.new(chat_id: chat_id, user_id: 1, status: @own)
    end
  end

  class MessageSender
    attr_reader :messages

    def initialize
      @messages = []
    end

    def send_message(chat_id:, text:, message_thread_id: nil, location_request: nil, ephemeral: nil)
      message = {chat_id: chat_id, text: text}
      message[:message_thread_id] = message_thread_id if message_thread_id
      message[:ephemeral] = ephemeral if ephemeral
      @messages << message
    end
  end

  class PublishPublication
    attr_reader :calls

    def initialize(error: nil)
      @error = error
      @calls = []
    end

    def call(publication:, idempotency_key:)
      raise @error if @error

      @calls << {publication: publication, idempotency_key: idempotency_key}
      {
        "status" => "ok",
        "request_id" => "request-test",
        "result" => {"data" => {"outcomes" => []}}
      }
    end
  end

  class ListChannels
    def call
      []
    end
  end

  class BotLifecycle
    def status(**)
      PrismBot::Domain::BotLifecycleState.new(status: "active")
    end

    def pause(**)
      PrismBot::Domain::BotLifecycleState.new(status: "paused")
    end

    def resume(**)
      PrismBot::Domain::BotLifecycleState.new(status: "active")
    end
  end

  module_function

  def services(message_sender:, publish_publication:, ephemeral_sender: EphemeralSender.new,
    chat_members: ChatMemberLookup.new)
    PrismBot::Client::Services.new(
      instance_id: "prism-hubot",
      default_channel_ids: ["personal-threads"],
      default_locale: "uk-UA",
      default_voice_profile: "0x0sky.uk_SP",
      dispatch_policy: "require_all_valid",
      message_sender: message_sender,
      ephemeral_message_sender: ephemeral_sender,
      voice_sender: ephemeral_sender,
      chat_member_lookup: chat_members,
      list_channels: ListChannels.new,
      publish_publication: publish_publication,
      bot_lifecycle: BotLifecycle.new
    )
  end

  def authorized_update(
    text:,
    update_id:,
    chat_id: 100,
    chat_type: "private",
    message_thread_id: nil,
    title: nil
  )
    surface = PrismBot::Channels::Telegram::SurfaceContext.new(
      chat_id: chat_id,
      chat_type: chat_type,
      message_thread_id: message_thread_id,
      title: title
    )
    update = PrismBot::Channels::Telegram::Update.new(
      update_id: update_id,
      chat_id: chat_id,
      user_id: 7,
      text: text,
      surface_context: surface
    )
    actor = PrismBot::Domain::HumanActor.new(
      canonical_id: "0x0sky",
      role: "owner"
    )
    PrismBot::Channels::Telegram::AuthorizedUpdate.new(
      update: update,
      actor: actor
    )
  end

  def human_actor
    PrismBot::Domain::HumanActor.new(canonical_id: "0x0sky", role: "owner")
  end

  # An ephemeral command as Telegram delivers it: marked with an ephemeral message id.
  def private_update(text:, chat_id: -1001, user_id: 7, thread: nil, chat_type: "supergroup", ephemeral_message_id: 5)
    message = {"message_id" => 0, "ephemeral_message_id" => ephemeral_message_id, "text" => text,
               "chat" => {"id" => chat_id, "type" => chat_type}, "from" => {"id" => user_id, "is_bot" => false}}
    message["message_thread_id"] = thread if thread
    parsed = PrismBot::Channels::Telegram::UpdateParser.new.call({"update_id" => 42, "message" => message})
    PrismBot::Channels::Telegram::AuthorizedUpdate.new(update: parsed, actor: human_actor)
  end

  # A button press on an ephemeral message (or a public one when source_ephemeral is nil).
  def callback_update(data:, chat_id: -1001, user_id: 7, thread: nil, source_ephemeral: 8)
    message = {"message_id" => source_ephemeral ? 0 : 99, "date" => 1_700_000_000,
               "chat" => {"id" => chat_id, "type" => "supergroup"}}
    message["ephemeral_message_id"] = source_ephemeral if source_ephemeral
    message["message_thread_id"] = thread if thread
    parsed = PrismBot::Channels::Telegram::UpdateParser.new.call(
      {"update_id" => 43, "callback_query" => {"id" => "cb-1", "from" => {"id" => user_id, "is_bot" => false},
                                               "data" => data, "message" => message}}
    )
    PrismBot::Channels::Telegram::AuthorizedUpdate.new(update: parsed, actor: human_actor)
  end

  def interaction_key(chat_id: 100, message_thread_id: nil)
    PrismBot::Domain::InteractionKey.new(
      instance_id: "prism-hubot",
      surface: "telegram:#{chat_id}:#{message_thread_id || 'root'}",
      actor_ref: "person:0x0sky"
    )
  end

  def router(composition)
    command_router = PrismBot::Channels::Telegram::CommandRouter.new(
      handlers: composition.command_handlers,
      fallback: composition.fallback
    )
    PrismBot::Channels::Telegram::InteractionRouter.new(
      command_router: command_router,
      state_handlers: composition.state_handlers,
      state_store: composition.state_store,
      instance_id: "prism-hubot"
    )
  end
end
