# © 2026 aiaiaiai · aiaiaiai.org

module PrismHubot
  class Client
    # history is process-local: nothing is retained across a restart, and every chat starts disabled.
    def initialize(state_store:, presenter: Presenter.new, history: Whisper::History.new)
      @state_store = state_store
      @presenter = presenter
      @history = history
    end

    def call(services)
      base = PrismBot::Client::Default.new(presenter: @presenter).call(services)
      begin_post = Handlers::BeginPost.new(message_sender: services.message_sender)
      cancel = Handlers::Cancel.new(message_sender: services.message_sender)
      await_post_content = Handlers::AwaitPostContent.new(
        publish_handler: base.command_handlers.fetch("publish"),
        message_sender: services.message_sender
      )

      whisper = whisper_handlers(services)

      base.with(
        command_handlers: {
          "post" => begin_post,
          "cancel" => cancel,
          "whisper" => whisper.fetch(:command),
          "whisper_off" => whisper.fetch(:off)
        },
        callback_handlers: {"wa" => whisper.fetch(:activation)},
        observers: [Whisper::Observer.new(history: @history)],
        state_handlers: {
          "awaiting_post_content" => await_post_content
        },
        fallback: Fallback.new(begin_post: begin_post, fallback: base.fallback),
        state_store: @state_store
      )
    end

    private

    def whisper_handlers(services)
      access = Whisper::Access.new(members: services.chat_member_lookup)
      responder = Whisper::Responder.new(
        message_sender: services.message_sender, ephemeral_sender: services.ephemeral_message_sender
      )
      shared = {history: @history, access: access, responder: responder}
      {
        command: Handlers::WhisperCommand.new(**shared),
        off: Handlers::WhisperOff.new(**shared),
        activation: Handlers::WhisperActivation.new(**shared)
      }
    end
  end
end
