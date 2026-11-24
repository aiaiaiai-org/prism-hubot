# © 2026 aiaiaiai · aiaiaiai.org

module PrismHubot
  module Handlers
    # /whisper, sent as an ephemeral command. Where Whisper is on it opens the private message list;
    # where it is off it says so and, for an administrator, offers to switch it on.
    class WhisperCommand
      ENABLE_DATA = "wa:on".freeze
      CANCEL_DATA = "wa:no".freeze

      def initialize(history:, access:, responder:, flow:)
        @history = history
        @access = access
        @responder = responder
        @flow = flow
      end

      def call(update:, arguments:)
        return @responder.hint_public(update) unless @responder.private_context?(update)
        return @responder.reply(update, Copy::WHISPER_NOT_A_GROUP) unless @responder.group?(update)

        surface = update.surface_context
        case @history.status(chat_id: surface.chat_id, topic_id: surface.message_thread_id)
        when :enabled then @flow.start(update, arguments)
        when :disabled_overflow then offer(update, Copy::WHISPER_OVERFLOW)
        else offer(update, Copy::WHISPER_NOT_ENABLED)
        end
      end

      private

      # Only an administrator is shown the consent buttons; the press is checked again regardless.
      def offer(update, refusal)
        case @access.check(chat_id: update.chat_id, user_id: update.user_id)
        when :ok then @responder.reply(update, Copy::WHISPER_ENABLE_DISCLOSURE, keyboard: keyboard)
        when :bot_not_admin then @responder.reply(update, Copy::WHISPER_BOT_NOT_ADMIN)
        when :unconfirmed then @responder.reply(update, Copy::WHISPER_UNCONFIRMED)
        else @responder.reply(update, refusal)
        end
      end

      def keyboard
        PrismBot::Domain::InlineKeyboard.new(rows: [[
          {text: Copy::WHISPER_ENABLE_BUTTON, callback_data: ENABLE_DATA},
          {text: Copy::WHISPER_CANCEL_BUTTON, callback_data: CANCEL_DATA}
        ]])
      end
    end
  end
end
