# © 2026 aiaiaiai · aiaiaiai.org

module PrismHubot
  # Single source of truth for the client command surface: the Telegram command
  # menu (`setMyCommands`) and the `/help` copy are both rendered from it, so the
  # two cannot drift.
  module CommandMenu
    # An ephemeral command is delivered by Telegram only to the bot, invisible to the group.
    Entry = Data.define(:command, :description, :ephemeral) do
      def initialize(command:, description:, ephemeral: false)
        super
      end
    end

    COMMAND_PATTERN = /\A[a-z0-9_]{1,32}\z/
    MAX_DESCRIPTION_LENGTH = 256
    MAX_ENTRIES = 100

    ENTRIES = [
      Entry.new(command: "start", description: "підключити себе до Prism"),
      Entry.new(command: "context", description: "показати поточний Telegram-контекст"),
      Entry.new(command: "post", description: "створити допис у два кроки"),
      Entry.new(command: "cancel", description: "скасувати поточну дію"),
      Entry.new(command: "channels", description: "доступні канали"),
      Entry.new(command: "status", description: "поточний стан бота"),
      Entry.new(command: "stop", description: "призупинити бота для себе"),
      Entry.new(command: "resume", description: "відновити бота"),
      Entry.new(command: "publish", description: "швидка публікація у типові канали"),
      Entry.new(command: "whisper", description: "приватно озвучити повідомлення групи", ephemeral: true),
      Entry.new(command: "whisper_off", description: "вимкнути Whisper у групі (адміністратор)", ephemeral: true),
      Entry.new(command: "help", description: "список команд")
    ].freeze

    module_function

    # Payload accepted by the Telegram Bot API `setMyCommands` method.
    def telegram_commands
      ENTRIES.map do |entry|
        command = {"command" => entry.command, "description" => entry.description}
        command["is_ephemeral"] = true if entry.ephemeral
        command
      end
    end

    def help_lines
      ENTRIES.map { "/#{_1.command} — #{_1.description}" }.join("\n")
    end
  end
end
