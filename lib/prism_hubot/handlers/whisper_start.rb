# © 2026 aiaiaiai · aiaiaiai.org

module PrismHubot
  module Handlers
    # /start, an ephemeral command for a group's administrators and creator. It switches Whisper on for
    # the group or topic it is sent in. Who may do that is read from Telegram at that moment and never
    # from the menu, which only hides the command from members.
    #
    # The group is told first, in public: members must be able to see that their messages are being
    # kept. If that notice cannot be posted, nothing is switched on.
    class WhisperStart
      def initialize(history:, access:, responder:)
        @history = history
        @access = access
        @responder = responder
      end

      def call(update:, arguments:)
        return @responder.hint_public(update) unless @responder.private_context?(update)
        return @responder.reply(update, Copy::WHISPER_NOT_A_GROUP) unless @responder.group?(update)

        case @access.check(chat_id: update.chat_id, user_id: update.user_id)
        when :ok then enable(update)
        when :bot_not_admin then @responder.reply(update, Copy::WHISPER_BOT_NOT_ADMIN)
        when :not_admin then @responder.reply(update, Copy::WHISPER_NOT_ADMIN)
        else @responder.reply(update, Copy::WHISPER_UNCONFIRMED)
        end
      end

      private

      def enable(update)
        surface = update.surface_context
        key = {chat_id: surface.chat_id, topic_id: surface.message_thread_id}
        return @responder.reply(update, Copy::WHISPER_ALREADY_ON) if @history.status(**key) == :enabled

        begin
          @responder.announce(update, Copy::WHISPER_ANNOUNCE_ON)
        rescue PrismBot::Error
          return @responder.reply(update, Copy::WHISPER_NOT_DISCLOSED)
        end
        begin
          @history.enable(**key)
        rescue PrismHubot::Whisper::Refusal
          return @responder.reply(update, Copy::WHISPER_CAPACITY)
        end
        @responder.reply(update, Copy::WHISPER_ENABLED)
      end
    end
  end
end
