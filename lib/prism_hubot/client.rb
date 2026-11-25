# © 2026 aiaiaiai · aiaiaiai.org

module PrismHubot
  class Client
    # history is process-local: nothing is retained across a restart, and every chat starts disabled.
    # speech is a Speech::Voice, or nil when text-to-speech is not configured: Whisper then lists and
    # chooses messages but says that voice is not available.
    def initialize(state_store:, presenter: Presenter.new, history: Whisper::History.new,
      sessions: Whisper::Sessions.new, picker_view: Whisper::PickerView.new, speech: nil, executor: nil,
      logger: Logger.new($stderr))
      @state_store = state_store
      @speech = speech
      @executor = executor
      @logger = logger
      @presenter = presenter
      @history = history
      @sessions = sessions
      @picker_view = picker_view
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
        callback_handlers: {"wa" => whisper.fetch(:activation), "wp" => whisper.fetch(:picker)},
        observers: [Whisper::Observer.new(history: @history)],
        state_handlers: {
          "awaiting_post_content" => await_post_content
        },
        fallback: Fallback.new(begin_post: begin_post, fallback: base.fallback),
        state_store: @state_store
      )
    end

    private

    def speaker(services, responder)
      return nil unless @speech

      Whisper::Speaker.new(
        voice: @speech, voice_sender: services.voice_sender, responder: responder,
        executor: @executor || Whisper::ThreadExecutor.new, logger: @logger
      )
    end

    def whisper_handlers(services)
      access = Whisper::Access.new(members: services.chat_member_lookup)
      responder = Whisper::Responder.new(
        message_sender: services.message_sender, ephemeral_sender: services.ephemeral_message_sender
      )
      shared = {history: @history, access: access, responder: responder}
      flow = Whisper::PickerFlow.new(
        history: @history, sessions: @sessions, view: @picker_view, responder: responder,
        speaker: speaker(services, responder)
      )
      {
        command: Handlers::WhisperCommand.new(**shared, flow: flow),
        picker: Handlers::WhisperPicker.new(flow: flow, responder: responder),
        off: Handlers::WhisperOff.new(**shared),
        activation: Handlers::WhisperActivation.new(**shared)
      }
    end
  end
end
