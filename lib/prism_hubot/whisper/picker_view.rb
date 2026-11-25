# © 2026 aiaiaiai · aiaiaiai.org

module PrismHubot
  module Whisper
    # Renders one page of the private message list: a short, safe snippet per message, newest first.
    # Content is only ever shown in a private message, and only as far as a snippet.
    class PickerView
      PAGE_SIZE = 10
      SNIPPET = 40
      AUTHOR = 16
      UNSAFE = /[[:cntrl:]​-‏ -‮⁠-⁤﻿]/

      def initialize(clock: -> { Time.now.to_i })
        @clock = clock
      end

      def pages(entries)
        [(entries.size.to_f / PAGE_SIZE).ceil, 1].max
      end

      # entries are newest first. Returns [text, keyboard].
      def render(entries, page:)
        total = pages(entries)
        page = page.clamp(1, total)
        slice = entries.slice((page - 1) * PAGE_SIZE, PAGE_SIZE)
        lines = slice.each_with_index.map { |entry, index| "#{index + 1}. #{ago(entry)} · #{short(entry.label, AUTHOR)}: #{short(entry.text, SNIPPET)}" }
        text = "#{Copy::PRIVATE}\n#{Copy::WHISPER_PICK}\nСторінка #{page}/#{total}.\n\n#{lines.join("\n")}"
        [text, keyboard(slice, page, total)]
      end

      private

      def keyboard(slice, page, total)
        rows = slice.each_with_index.map do |entry, index|
          label = "#{index + 1}. #{short(entry.label, AUTHOR)}: #{short(entry.text, SNIPPET)}"
          [{text: label[0, PrismBot::Domain::InlineKeyboard::MAX_LABEL_CHARACTERS], callback_data: "wp:s:#{entry.id}"}]
        end
        navigation = []
        navigation << {text: "◀", callback_data: "wp:p:#{page - 1}"} if page > 1
        navigation << {text: "▶", callback_data: "wp:p:#{page + 1}"} if page < total
        navigation << {text: Copy::WHISPER_CANCEL_BUTTON, callback_data: "wp:x"}
        PrismBot::Domain::InlineKeyboard.new(rows: rows + [navigation])
      end

      def short(text, limit)
        clean = text.gsub(UNSAFE, " ").gsub(/\s+/, " ").strip
        clean.length > limit ? "#{clean[0, limit - 1].rstrip}…" : clean
      end

      def ago(entry)
        minutes = [(@clock.call - entry.timestamp) / 60, 0].max
        if minutes < 1 then "щойно"
        elsif minutes < 60 then "#{minutes} хв тому"
        else "#{minutes / 60} год тому"
        end
      end
    end
  end
end
