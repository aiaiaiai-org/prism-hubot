# © 2026 aiaiaiai · aiaiaiai.org

module PrismHubot
  module Whisper
    # Feeds ordinary group messages to the history. The history keeps only chats that an administrator
    # enabled, so for every other chat this retains nothing. Commands are requests to the bot, not
    # conversation, and are skipped.
    class Observer
      FALLBACK_LABEL = "Учасник".freeze

      def initialize(history:)
        @history = history
      end

      def call(observation)
        return false if observation.command?

        @history.observe(
          chat_id: observation.chat_id,
          topic_id: observation.message_thread_id,
          id: observation.message_id,
          # The first sighting is revision 1; an edit carries the id of its own update, which only grows.
          revision: observation.edited? ? observation.update_id : 1,
          timestamp: observation.sent_at,
          author_id: observation.author_id,
          label: label_for(observation),
          username: observation.username,
          text: observation.text
        )
      end

      private

      # A label is spoken as an author cue: no control, invisible or line-break characters.
      def label_for(observation)
        raw = observation.display_name.to_s.empty? ? observation.username.to_s : observation.display_name
        clean = raw.gsub(/[[:cntrl:]​-‏ -‮⁠-⁤﻿]/, " ").squeeze(" ").strip
        clean = clean[0, History::MAX_LABEL].strip
        clean.empty? ? FALLBACK_LABEL : clean
      end
    end
  end
end
