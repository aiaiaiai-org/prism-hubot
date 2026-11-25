# © 2026 aiaiaiai · aiaiaiai.org

module PrismHubot
  # Single source of truth for the client command surface: the Telegram command menus
  # (`setMyCommands`, one list per scope) and the help copy are rendered from it, so they cannot drift.
  #
  # There are four commands. /start and /stop switch Whisper on and off for a group or topic and are
  # for its administrators and creator only; /whisper and /whisper_private are for every member, once
  # Whisper has been started, and differ in who hears the result. The menu shows /start and /stop only
  # to administrators; the handlers check Telegram's own member status regardless of the menu.
  module CommandMenu
    # An ephemeral command is delivered by Telegram only to the bot, invisible to the group.
    Entry = Data.define(:command, :description, :ephemeral, :administrators_only) do
      def initialize(command:, description:, ephemeral: false, administrators_only: false)
        super
      end
    end

    COMMAND_PATTERN = /\A[a-z0-9_]{1,32}\z/
    MAX_DESCRIPTION_LENGTH = 256
    MAX_ENTRIES = 100

    ENTRIES = [
      Entry.new(command: "start", description: "увімкнути Whisper у цій групі (адміністратор)",
        ephemeral: true, administrators_only: true),
      Entry.new(command: "stop", description: "вимкнути Whisper і стерти збережені тексти (адміністратор)",
        ephemeral: true, administrators_only: true),
      Entry.new(command: "whisper", description: "озвучити повідомлення для всіх у групі", ephemeral: true),
      Entry.new(command: "whisper_private", description: "озвучити повідомлення лише для себе", ephemeral: true)
    ].freeze

    # Where each list is shown. A more specific scope replaces the default one, so administrators get
    # all four; everyone else in a group gets the two for members; private chats get none, because
    # Whisper reads groups.
    SCOPES = [
      {scope: {"type" => "default"}, administrators_only: false},
      {scope: {"type" => "all_chat_administrators"}, administrators_only: nil},
      {scope: {"type" => "all_private_chats"}, none: true}
    ].freeze

    module_function

    # Payload accepted by the Telegram Bot API `setMyCommands` method, for the default scope.
    def telegram_commands(entries = member_entries)
      entries.map do |entry|
        command = {"command" => entry.command, "description" => entry.description}
        command["is_ephemeral"] = true if entry.ephemeral
        command
      end
    end

    # [{"scope" => {...}, "commands" => [...]}]: an empty list means the scope's menu is removed.
    def telegram_menus
      SCOPES.map do |definition|
        entries =
          if definition[:none] then []
          elsif definition[:administrators_only].nil? then ENTRIES
          else member_entries
          end
        {"scope" => definition.fetch(:scope), "commands" => telegram_commands(entries)}
      end
    end

    def member_entries
      ENTRIES.reject(&:administrators_only)
    end

    def help_lines
      ENTRIES.map { "/#{_1.command} — #{_1.description}" }.join("\n")
    end
  end
end
