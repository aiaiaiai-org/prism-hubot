# © 2026 aiaiaiai · aiaiaiai.org

module PrismHubot
  module Handlers
    # Buttons of the message list (callback route "wp"): "p:<page>", "s:<message id>" and "x".
    # The data is untrusted; anything that is not exactly one of these shapes is ignored.
    class WhisperPicker
      NUMBER = /\A[1-9]\d{0,9}\z/

      def initialize(flow:, responder:)
        @flow = flow
        @responder = responder
      end

      def call(update:, arguments:)
        return unless @responder.group?(update)

        kind, value = arguments.split(":", 2)
        case kind
        when "p" then @flow.page(update, value.to_i) if NUMBER.match?(value.to_s)
        when "s" then @flow.choose(update, value.to_i) if NUMBER.match?(value.to_s)
        when "x" then @flow.close(update) if value.nil?
        end
      end
    end
  end
end
