# © 2026 aiaiaiai · aiaiaiai.org

module PrismHubot
  module Handlers
    # The consent buttons under the /whisper disclosure (callback route "wa"). A press is authority
    # only for the chat it was pressed in, and only if the person who pressed it is an administrator
    # right now; the data on the button is never trusted for either.
    #
    # The group is told first. If that notice cannot be posted, nothing is switched on, because
    # members must be able to see that their messages are being kept.
    class WhisperActivation
      def initialize(history:, access:, responder:)
        @history = history
        @access = access
        @responder = responder
      end

      def call(update:, arguments:)
        return unless @responder.group?(update)

        case arguments
        when "on" then enable(update)
        when "no" then @responder.settle(update, Copy::WHISPER_CANCELLED)
        end
      end

      private

      def enable(update)
        refusal = refusal_for(update)
        return @responder.settle(update, refusal) if refusal

        surface = update.surface_context
        begin
          @responder.announce(update, Copy::WHISPER_ANNOUNCE_ON)
        rescue PrismBot::Error
          return @responder.settle(update, Copy::WHISPER_NOT_DISCLOSED)
        end
        begin
          @history.enable(chat_id: surface.chat_id, topic_id: surface.message_thread_id)
        rescue PrismHubot::Whisper::Refusal
          return @responder.settle(update, Copy::WHISPER_CAPACITY)
        end
        @responder.settle(update, Copy::WHISPER_ENABLED)
      end

      def refusal_for(update)
        case @access.check(chat_id: update.chat_id, user_id: update.user_id)
        when :ok then nil
        when :bot_not_admin then Copy::WHISPER_BOT_NOT_ADMIN
        when :not_admin then Copy::WHISPER_NOT_ADMIN
        else Copy::WHISPER_UNCONFIRMED
        end
      end
    end
  end
end
