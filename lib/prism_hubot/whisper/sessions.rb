# © 2026 aiaiaiai · aiaiaiai.org

require "thread"

module PrismHubot
  module Whisper
    Session = Data.define(:snapshot, :limit, :screen, :anchor) do
      def inspect
        "#<Whisper::Session redacted>"
      end
    end

    # One open picker per person per chat or topic, in memory only. It holds the immutable snapshot
    # (references, never text) and what the person asked for, never message content, and it expires
    # with the snapshot. A press can only reach the session of the person who pressed.
    class Sessions
      MAX_SESSIONS = 200

      def initialize(clock: -> { Time.now.to_i })
        @clock = clock
        @lock = Mutex.new
        @sessions = {}
      end

      def inspect
        "#<Whisper::Sessions redacted>"
      end

      def open(chat_id:, topic_id:, user_id:, snapshot:, limit: nil, screen: false)
        @lock.synchronize do
          prune
          @sessions.shift while @sessions.size >= MAX_SESSIONS
          # Returns the session it just stored.
          @sessions[key(chat_id, topic_id, user_id)] = Session.new(snapshot:, limit:, screen:, anchor: nil)
        end
      end

      def fetch(chat_id:, topic_id:, user_id:)
        @lock.synchronize do
          prune
          @sessions[key(chat_id, topic_id, user_id)]
        end
      end

      def choose(chat_id:, topic_id:, user_id:, anchor:)
        @lock.synchronize do
          k = key(chat_id, topic_id, user_id)
          current = @sessions[k] or return nil
          @sessions[k] = current.with(anchor: anchor)
        end
      end

      def close(chat_id:, topic_id:, user_id:)
        @lock.synchronize { @sessions.delete(key(chat_id, topic_id, user_id)) }
        nil
      end

      private

      def key(chat_id, topic_id, user_id)
        [chat_id, topic_id, user_id].freeze
      end

      def prune
        now = @clock.call
        @sessions.delete_if { |_, session| session.snapshot.expires_at <= now }
      end
    end
  end
end
