# © 2026 aiaiaiai · aiaiaiai.org

module PrismHubot
  module Whisper
    # Who may switch Whisper on or off for a chat. Telegram answers about other people only when the
    # bot is itself an administrator, so that is checked first, and a lookup that Telegram does not
    # confirm is never read as permission.
    class Access
      def initialize(members:)
        @members = members
      end

      # :ok, :bot_not_admin, :not_admin or :unconfirmed
      def check(chat_id:, user_id:)
        return :bot_not_admin unless @members.own_membership(chat_id: chat_id).administrator?

        @members.chat_membership(chat_id: chat_id, user_id: user_id).administrator? ? :ok : :not_admin
      rescue PrismBot::MessageDeliveryError, PrismBot::ConfigurationError, PrismBot::InputError
        :unconfirmed
      end
    end
  end
end
