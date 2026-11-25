# © 2026 aiaiaiai · aiaiaiai.org

module PrismHubot
  module Handlers
    # /stop, an ephemeral command for a group's administrators and creator. Collection stops and retained
    # texts are dropped first; telling the group is best effort and cannot undo that.
    class WhisperStop
      def initialize(history:, access:, responder:)
        @history = history
        @access = access
        @responder = responder
      end

      def call(update:, arguments:)
        return @responder.hint_public(update) unless @responder.private_context?(update)
        return @responder.reply(update, Copy::WHISPER_NOT_A_GROUP) unless @responder.group?(update)

        case @access.check(chat_id: update.chat_id, user_id: update.user_id)
        when :ok then disable(update)
        when :bot_not_admin then @responder.reply(update, Copy::WHISPER_BOT_NOT_ADMIN)
        when :not_admin then @responder.reply(update, Copy::WHISPER_NOT_ADMIN)
        else @responder.reply(update, Copy::WHISPER_UNCONFIRMED)
        end
      end

      private

      def disable(update)
        surface = update.surface_context
        key = {chat_id: surface.chat_id, topic_id: surface.message_thread_id}
        return @responder.reply(update, Copy::WHISPER_ALREADY_OFF) if @history.status(**key) == :not_enabled

        @history.disable(**key)
        begin
          @responder.announce(update, Copy::WHISPER_ANNOUNCE_OFF)
        rescue PrismBot::Error
          nil
        end
        @responder.reply(update, Copy::WHISPER_DISABLED)
      end
    end
  end
end
