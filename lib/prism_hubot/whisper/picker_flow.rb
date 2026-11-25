# © 2026 aiaiaiai · aiaiaiai.org

module PrismHubot
  module Whisper
    # /whisper in a chat where Whisper is on: a private, paged list of recently kept messages, newest
    # first. Choosing one fixes it as the inclusive start of the range; the range itself is read from
    # the history again, and revalidated, when it is synthesized. Every step re-reads the person's own
    # session, so a press can never act on someone else's list.
    class PickerFlow
      MAX_LIMIT = 50
      # With no number the list shows the newest ten of whoever was asked for; a number (1-50) is the most
      # messages of the union of the chosen authors, never per author, and `екран` keeps its own preset.
      DEFAULT_LIMIT = 10
      HANDLE = /\A@[A-Za-z0-9_]{1,64}\z/
      SCREEN = %w[екран screen].freeze

      Request = Data.define(:usernames, :limit, :screen)

      def initialize(history:, sessions:, view:, responder:, speaker: nil)
        @history = history
        @sessions = sessions
        @view = view
        @responder = responder
        @speaker = speaker
      end

      # visibility is :private (only the person hears the result) or :public (the whole group does);
      # the list itself is private either way.
      def start(update, arguments, visibility: :private)
        request = parse(arguments)
        return @responder.reply(update, Copy::WHISPER_USAGE) unless request

        snapshot = @history.snapshot(
          chat_id: update.chat_id, topic_id: topic(update), actor: update.user_id, usernames: request.usernames
        )
        session = @sessions.open(chat_id: update.chat_id, topic_id: topic(update), user_id: update.user_id,
          snapshot: snapshot, limit: request.limit, screen: request.screen, visibility: visibility)
        text, keyboard = @view.render(entries(update, session), page: 1)
        @responder.reply(update, text, keyboard: keyboard)
      rescue Refusal => refusal
        @responder.refuse(update, refusal.message)
      end

      def page(update, number)
        session = fetch(update) or return stale(update)

        text, keyboard = @view.render(entries(update, session), page: number)
        @responder.settle(update, text, keyboard: keyboard)
      rescue Refusal => refusal
        @responder.refuse(update, refusal.message, settle: true)
      end

      def choose(update, anchor)
        session = fetch(update) or return stale(update)

        chosen = @history.select(
          session.snapshot, chat_id: update.chat_id, topic_id: topic(update), actor: update.user_id,
          anchor: anchor, screen: session.screen
        )
        @sessions.choose(chat_id: update.chat_id, topic_id: topic(update), user_id: update.user_id, anchor: anchor)
        narration = @history.narrate(chosen)
        figures = {count: chosen.size, characters: narration.length}
        return @responder.settle(update, format(Copy::WHISPER_CHOSEN, **figures)) unless @speaker

        visibility = session.visibility
        speaking = (visibility == :public) ? Copy::WHISPER_CHOSEN_SPEAKING_PUBLIC : Copy::WHISPER_CHOSEN_SPEAKING
        started = @speaker.start(update, narration, visibility: visibility) { @responder.settle(update, format(speaking, **figures)) }
        @responder.settle(update, Copy::WHISPER_VOICE_BUSY) if started == :busy
      rescue Refusal => refusal
        @responder.refuse(update, refusal.message, settle: true)
      end

      def close(update)
        @sessions.close(chat_id: update.chat_id, topic_id: topic(update), user_id: update.user_id)
        @responder.settle(update, Copy::WHISPER_PICKER_CLOSED)
      end

      private

      def topic(update)
        update.surface_context.message_thread_id
      end

      def fetch(update)
        @sessions.fetch(chat_id: update.chat_id, topic_id: topic(update), user_id: update.user_id)
      end

      def stale(update)
        @responder.settle(update, Copy::WHISPER_PICKER_STALE)
      end

      def entries(update, session)
        listed = @history.picker(session.snapshot, chat_id: update.chat_id, topic_id: topic(update), actor: update.user_id)
        session.limit ? listed.first(session.limit) : listed
      end

      # nil when anything is not understood: guessing at a range would read the wrong messages.
      def parse(arguments)
        usernames = []
        limit = nil
        screen = false
        arguments.to_s.split.each do |token|
          if HANDLE.match?(token)
            usernames << token
          elsif /\A\d{1,2}\z/.match?(token) && limit.nil? && (1..MAX_LIMIT).cover?(token.to_i)
            limit = token.to_i
          elsif SCREEN.include?(token.downcase) && !screen
            screen = true
          else
            return nil
          end
        end
        Request.new(usernames: usernames.uniq, limit: limit || (DEFAULT_LIMIT unless screen), screen: screen)
      end
    end
  end
end
