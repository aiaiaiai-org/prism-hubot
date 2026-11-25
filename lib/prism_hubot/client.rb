# © 2026 aiaiaiai · aiaiaiai.org

module PrismHubot
  # Prism Hubot is a Whisper bot: four commands and nothing else. /start and /stop are for a group's
  # administrators and creator, /whisper and /whisper_private for every member once Whisper is on.
  # All four are open commands (prism-bot): nobody needs a Hub identity to use them, and each handler
  # decides from Telegram's own member status what its sender may do. Every other message and command
  # is ignored, and the Hub-backed commands of prism-bot's default client (posting, publishing,
  # channels, bot status) are not part of this client.
  class Client
    COMMANDS = %w[start stop whisper whisper_private].freeze

    # history is process-local: nothing is retained across a restart, and every chat starts disabled.
    # speech is a Speech::Voice, or nil when text-to-speech is not configured: Whisper then lists and
    # chooses messages but says that voice is not available.
    def initialize(state_store:, presenter: Presenter.new, history: Whisper::History.new,
      sessions: Whisper::Sessions.new, picker_view: Whisper::PickerView.new, speech: nil, executor: nil,
      logger: Logger.new($stderr))
      @state_store = state_store
      @presenter = presenter
      @history = history
      @sessions = sessions
      @picker_view = picker_view
      @speech = speech
      @executor = executor
      @logger = logger
    end

    def call(services)
      whisper = whisper_handlers(services)

      PrismBot::Client::Composition.new(
        command_handlers: {
          "start" => whisper.fetch(:start),
          "stop" => whisper.fetch(:stop),
          "whisper" => whisper.fetch(:public),
          "whisper_private" => whisper.fetch(:private)
        },
        open_commands: COMMANDS,
        callback_handlers: {"wp" => whisper.fetch(:picker)},
        observers: [Whisper::Observer.new(history: @history)],
        fallback: ->(update:, arguments:) { },
        presenter: @presenter,
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
      flow = Whisper::PickerFlow.new(
        history: @history, sessions: @sessions, view: @picker_view, responder: responder,
        speaker: speaker(services, responder)
      )
      shared = {history: @history, responder: responder}
      {
        start: Handlers::WhisperStart.new(**shared, access: access),
        stop: Handlers::WhisperStop.new(**shared, access: access),
        public: Handlers::WhisperCommand.new(**shared, flow: flow, visibility: :public),
        private: Handlers::WhisperCommand.new(**shared, flow: flow, visibility: :private),
        picker: Handlers::WhisperPicker.new(flow: flow, responder: responder)
      }
    end
  end
end
