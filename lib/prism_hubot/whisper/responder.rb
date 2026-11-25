# © 2026 aiaiaiai · aiaiaiai.org

module PrismHubot
  module Whisper
    # Answers a Whisper request. A reply is private only if the update is: an ephemeral command or a
    # button press, or a private chat. In a group, an ordinary message is public and gets no private
    # content, only a hint.
    class Responder
      def initialize(message_sender:, ephemeral_sender:)
        @message_sender = message_sender
        @ephemeral_sender = ephemeral_sender
      end

      # The request arrived in a way that keeps the answer between the bot and the sender.
      def private_context?(update)
        update.private? || update.surface_context.chat_type == "private"
      end

      def group?(update)
        %w[group supergroup].include?(update.surface_context.chat_type)
      end

      def hint_public(update)
        @message_sender.send_message(**update.surface_context.reply_target, text: Copy::WHISPER_PUBLIC_HINT)
      end

      def reply(update, text, keyboard: nil)
        if keyboard
          @ephemeral_sender.send_ephemeral_message(target: update.reply_target.fetch(:ephemeral), text: text,
            reply_markup: keyboard)
        else
          @message_sender.send_message(**update.reply_target, text: text)
        end
      end

      # The pressed button sits on an ephemeral message: edit it in place instead of adding another.
      def settle(update, text, keyboard: nil)
        ref = update.source_ephemeral_ref
        if ref
          return @ephemeral_sender.edit_ephemeral_message(ref: ref, text: text, reply_markup: keyboard)
        end
        return reply(update, text, keyboard: keyboard) if keyboard

        @message_sender.send_message(**update.reply_target, text: text)
      end

      # Edits the private status message and nothing else: unlike #settle it never falls back to a public
      # message, because it runs after the request is over and has no right to speak to the group.
      def settle_private(update, text)
        ref = update.source_ephemeral_ref
        return nil unless ref

        @ephemeral_sender.edit_ephemeral_message(ref: ref, text: text, reply_markup: nil)
      end

      def refuse(update, reason, settle: false)
        text = "#{Copy::PRIVATE}\n#{Copy::WHISPER_REFUSALS.fetch(reason, Copy::WHISPER_REFUSAL_FALLBACK)}"
        settle ? self.settle(update, text) : reply(update, text)
      end

      # A deliberate public message, to the same chat and topic and never ephemeral.
      def announce(update, text)
        @message_sender.send_message(**update.surface_context.reply_target, text: text)
      end
    end
  end
end
