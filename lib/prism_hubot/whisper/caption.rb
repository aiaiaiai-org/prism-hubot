# © 2026 aiaiaiai · aiaiaiai.org

module PrismHubot
  module Whisper
    # The caption of a voice message: its audience label, then whose messages are in it. Only the
    # authors whose messages were actually read are named, in the order they first speak, not everyone
    # the request mentioned. Telegram allows 1024 characters; when the names do not all fit, the rest is
    # counted instead of cut mid-name.
    module Caption
      LIMIT = 1024
      FROM = "Повідомлення від: ".freeze

      module_function

      # audience is Copy::PRIVATE or Copy::PUBLIC; authors are display labels, first appearance first.
      def build(audience, authors)
        names = authors.uniq
        head = "#{audience}\n#{FROM}"
        return audience if names.empty?

        shown = []
        names.each_with_index do |name, index|
          rest = names.size - index - 1
          candidate = shown + [name]
          tail = rest.zero? ? "" : " та ще #{rest}"
          break if "#{head}#{candidate.join(", ")}#{tail}".length > LIMIT

          shown = candidate
        end
        return "#{head}#{names.size}".slice(0, LIMIT) if shown.empty?

        hidden = names.size - shown.size
        "#{head}#{shown.join(", ")}#{" та ще #{hidden}" if hidden.positive?}"
      end
    end
  end
end
