# © 2026 aiaiaiai · aiaiaiai.org

module PrismHubot
  module Handlers
    # /whisper and /whisper_private, sent as ephemeral commands by any member. Where Whisper is on they
    # open the same private message list; the visibility decides who hears the result: everyone in the
    # group (:public) or only the person who asked (:private). Where Whisper is off they say so: only an
    # administrator's /start switches it on.
    class WhisperCommand
      def initialize(history:, responder:, flow:, visibility:)
        @history = history
        @responder = responder
        @flow = flow
        @visibility = visibility
      end

      def call(update:, arguments:)
        return @responder.hint_public(update) unless @responder.private_context?(update)
        return @responder.reply(update, Copy::WHISPER_NOT_A_GROUP) unless @responder.group?(update)

        surface = update.surface_context
        case @history.status(chat_id: surface.chat_id, topic_id: surface.message_thread_id)
        when :enabled then @flow.start(update, arguments, visibility: @visibility)
        when :disabled_overflow then @responder.reply(update, Copy::WHISPER_OVERFLOW)
        else @responder.reply(update, Copy::WHISPER_NOT_ENABLED)
        end
      end
    end
  end
end
