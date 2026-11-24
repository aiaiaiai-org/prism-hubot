# © 2026 aiaiaiai · aiaiaiai.org

require "securerandom"
require "thread"

module PrismHubot
  module Whisper
    class Refusal < StandardError; end

    Entry = Data.define(:id, :revision, :timestamp, :author_id, :label, :username, :text) do
      def inspect
        "#<Whisper::Entry redacted>"
      end
    end

    Snapshot = Data.define(:surface, :actor, :epoch, :expires_at, :references) do
      def inspect
        "#<Whisper::Snapshot redacted>"
      end
    end

    # Process-local, bounded history for one configured bot instance.
    # The caller must verify administrator authorization and disclose retention
    # before enable; only normalized, authenticated eligible messages reach observe.
    class History
      MAX_MESSAGES = 100
      MAX_AGE = 86_400
      MAX_SURFACES = 100
      # Telegram limits text to 4096 characters; narration is capped lower so a
      # selection fits the speech service's duration limit (about 4,000 characters).
      MAX_TEXT = 4_096
      MAX_NARRATION = 4_000
      MAX_LABEL = 128
      MAX_SNAPSHOT_AGE = 600
      MAX_TOMBSTONES = 200

      def initialize(clock: -> { Time.now.to_i })
        @clock = clock
        @lock = Mutex.new
        @surfaces = {}
        @overflowed = {}
      end

      def inspect
        "#<Whisper::History redacted>"
      end

      def enable(chat_id:, topic_id: nil)
        key = surface(chat_id, topic_id)
        @lock.synchronize do
          return if @surfaces.key?(key)
          raise Refusal, "surface_capacity" if @surfaces.size >= MAX_SURFACES

          @overflowed.delete(key)
          # Nothing sent before this moment is eligible, including later edits of it.
          @surfaces[key] = {epoch: SecureRandom.hex(16), entries: {}, deleted: {}, floor: 0,
                            enabled_at: @clock.call}
        end
      end

      def disable(chat_id:, topic_id: nil)
        key = surface(chat_id, topic_id)
        @lock.synchronize do
          @surfaces.delete(key)
          @overflowed.delete(key)
        end
        nil
      end

      def observe(chat_id:, topic_id: nil, id:, revision:, timestamp:, author_id:, label:, username: nil, text:)
        key = surface(chat_id, topic_id)
        @lock.synchronize do
          state = @surfaces[key]
          return false unless state

          now = @clock.call
          prune(state, now)
          return false unless positive?(id) && positive?(revision) && positive?(author_id)
          return false unless timestamp.is_a?(Integer) && timestamp <= now && timestamp > now - MAX_AGE
          return false if timestamp < state[:enabled_at]
          return false if id <= state[:floor] || state[:deleted].key?(id)
          return false unless valid_string?(text, MAX_TEXT) && valid_label?(label)
          return false unless username.nil? || (valid_string?(username, 64) && /\A[A-Za-z0-9_]+\z/.match?(username))

          old = state[:entries][id]
          return false if old && (old.revision >= revision || old.author_id != author_id || old.timestamp != timestamp)

          state[:entries][id] = Entry.new(id:, revision:, timestamp:, author_id:,
            label: label.dup.freeze, username: username&.downcase&.freeze, text: text.dup.freeze)
          while state[:entries].size > MAX_MESSAGES
            retired = state[:entries].keys.min
            state[:entries].delete(retired)
            state[:floor] = [state[:floor], retired].max
          end
          state[:entries].key?(id)
        end
      end

      # An actual verified deletion notification, not a claim of complete
      # Telegram deletion coverage. A bounded tombstone prevents replay.
      def forget(chat_id:, topic_id: nil, id:)
        key = surface(chat_id, topic_id)
        @lock.synchronize do
          state = @surfaces[key]
          return unless state && positive?(id) && id > state[:floor]

          state[:entries].delete(id)
          state[:deleted][id] = true
          if state[:deleted].size > MAX_TOMBSTONES
            # Fail closed instead of discarding deletion evidence. The marker keeps
            # the cause distinguishable until an administrator enables it again.
            @surfaces.delete(key)
            @overflowed[key] = true
            @overflowed.shift while @overflowed.size > MAX_SURFACES
          end
        end
        nil
      end

      # Snapshots contain references only, never a second copy of retained text.
      # Handles are resolved within the observed surface, never as identity keys.
      def snapshot(chat_id:, topic_id: nil, actor:, usernames: [])
        key = surface(chat_id, topic_id)
        raise Refusal, "invalid_actor" unless positive?(actor)

        @lock.synchronize do
          state = @surfaces[key] || raise(Refusal, @overflowed.key?(key) ? "disabled_overflow" : "not_enabled")
          now = @clock.call
          prune(state, now)
          entries = state[:entries].values.sort_by(&:id)
          unless usernames.empty?
            raise Refusal, "invalid_filter" unless usernames.is_a?(Array) && usernames.size <= 10

            ids = usernames.map do |handle|
              raise Refusal, "invalid_filter" unless handle.is_a?(String) && /\A@?[A-Za-z0-9_]{1,64}\z/.match?(handle)

              name = handle.delete_prefix("@").downcase
              matches = entries.select { |entry| entry.username == name }.map(&:author_id).uniq
              raise Refusal, "unresolved_author" unless matches.size == 1

              matches.first
            end
            entries = entries.select { |entry| ids.include?(entry.author_id) }
          end
          raise Refusal, "history_unavailable" if entries.empty?

          refs = entries.map { |entry| [entry.id, entry.revision].freeze }.freeze
          Snapshot.new(surface: key, actor:, epoch: state[:epoch].dup.freeze,
            expires_at: now + MAX_SNAPSHOT_AGE, references: refs)
        end
      end

      def picker(snapshot, chat_id:, topic_id: nil, actor:)
        @lock.synchronize do
          entries = resolve(snapshot, surface(chat_id, topic_id), actor)
          entries.reverse.freeze
        end
      end

      # The picker reads forward; Reply count reads backward, inclusive.
      # Never silently truncate. Returned content is transient caller-owned
      # memory; revalidate immediately before any later delivery.
      def select(snapshot, chat_id:, topic_id: nil, actor:, anchor:, backward_count: nil, screen: false)
        @lock.synchronize do
          entries = resolve(snapshot, surface(chat_id, topic_id), actor)
          index = entries.index { |entry| entry.id == anchor }
          raise Refusal, "anchor_unavailable" unless index

          if backward_count
            raise Refusal, "range_limit" unless positive?(backward_count) && backward_count <= 50
            raise Refusal, "history_unavailable" if index + 1 < backward_count

            entries = entries[(index + 1 - backward_count)..index]
          else
            entries = entries[index..]
          end
          limit = screen ? 20 : 50
          characters = screen ? 2_000 : MAX_NARRATION
          raise Refusal, "range_limit" if entries.size > limit || narrate(entries).length > characters

          entries.freeze
        end
      end

      def narrate(entries)
        previous = nil
        entries.map do |entry|
          prefix = entry.author_id == previous ? "" : "#{entry.label}: "
          previous = entry.author_id
          "#{prefix}#{entry.text}"
        end.join("\n")
      end

      private

      def positive?(value)
        value.is_a?(Integer) && value.positive?
      end

      def valid_string?(value, maximum)
        value.is_a?(String) && value.valid_encoding? && !value.strip.empty? && value.length <= maximum
      end

      # Labels are spoken as author cues: no line breaks, control or invisible characters.
      def valid_label?(value)
        valid_string?(value, MAX_LABEL) && !value.match?(/[[:cntrl:]\u200B-\u200F\u2028-\u202E\u2060-\u2064\uFEFF]/)
      end

      def surface(chat_id, topic_id)
        unless chat_id.is_a?(Integer) && !chat_id.zero? && (topic_id.nil? || positive?(topic_id))
          raise Refusal, "invalid_surface"
        end

        [chat_id, topic_id].freeze
      end

      def prune(state, now)
        expired = state[:entries].values.select { |entry| entry.timestamp <= now - MAX_AGE }
        expired.each { |entry| state[:entries].delete(entry.id) }
        # Retire IDs below the high-water mark to reject stale replays.
        unless expired.empty?
          state[:floor] = [state[:floor], expired.map(&:id).max].max
          state[:entries].delete_if { |id, _| id <= state[:floor] }
        end
        state[:deleted].delete_if { |id, _| id <= state[:floor] }
      end

      def resolve(snapshot, key, actor)
        unless snapshot.is_a?(Snapshot) && snapshot.surface == key && snapshot.actor == actor
          raise Refusal, "invalid_snapshot"
        end

        state = @surfaces[key]
        now = @clock.call
        unless state && state[:epoch] == snapshot.epoch && now < snapshot.expires_at
          raise Refusal, "stale_snapshot"
        end

        prune(state, now)
        snapshot.references.map do |id, revision|
          entry = state[:entries][id]
          raise Refusal, "stale_snapshot" unless entry && entry.revision == revision

          entry
        end
      end
    end
  end
end
