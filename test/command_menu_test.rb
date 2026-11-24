# © 2026 aiaiaiai · aiaiaiai.org

require_relative "test_helper"

class CommandMenuTest < Minitest::Test
  def test_entries_satisfy_telegram_constraints
    entries = PrismHubot::CommandMenu::ENTRIES

    assert_operator entries.length, :<=, PrismHubot::CommandMenu::MAX_ENTRIES
    assert_equal entries.map(&:command), entries.map(&:command).uniq

    entries.each do |entry|
      assert_match PrismHubot::CommandMenu::COMMAND_PATTERN, entry.command
      assert_operator entry.description.length, :<=, PrismHubot::CommandMenu::MAX_DESCRIPTION_LENGTH
      refute_empty entry.description
      refute_includes entry.description, "\n"
    end
  end

  def test_menu_covers_every_routed_command
    state_store = PrismHubotTestSupport::MemoryStateStore.new
    composition = PrismHubot::Client.new(state_store: state_store).call(
      PrismHubotTestSupport.services(
        message_sender: PrismHubotTestSupport::MessageSender.new,
        publish_publication: PrismHubotTestSupport::PublishPublication.new
      )
    )

    assert_equal(
      composition.command_handlers.keys.sort,
      PrismHubot::CommandMenu::ENTRIES.map(&:command).sort
    )
  end

  def test_help_copy_is_rendered_from_the_menu
    PrismHubot::CommandMenu::ENTRIES.each do |entry|
      assert_includes PrismHubot::Copy::HELP, "/#{entry.command} — #{entry.description}"
    end
  end

  def test_telegram_payload_shape
    payload = PrismHubot::CommandMenu.telegram_commands

    assert_equal PrismHubot::CommandMenu::ENTRIES.length, payload.length
    assert_equal %w[command description], payload.first.keys
  end

  def test_whisper_commands_are_declared_ephemeral_and_nothing_else_is
    payload = PrismHubot::CommandMenu.telegram_commands
    ephemeral = payload.select { _1["is_ephemeral"] }.map { _1["command"] }

    assert_equal %w[whisper whisper_off], ephemeral
    payload.reject { _1["is_ephemeral"] }.each { |command| refute_includes command.keys, "is_ephemeral" }
  end
end
