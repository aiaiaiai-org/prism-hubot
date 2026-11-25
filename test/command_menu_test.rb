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
    assert_equal composition.command_handlers.keys.sort, composition.open_commands.sort
  end

  def test_help_copy_is_rendered_from_the_menu
    PrismHubot::CommandMenu::ENTRIES.each do |entry|
      assert_includes PrismHubot::Copy::HELP, "/#{entry.command} — #{entry.description}"
    end
  end

  def test_there_are_exactly_four_commands_and_two_are_for_administrators
    entries = PrismHubot::CommandMenu::ENTRIES

    assert_equal %w[start stop whisper whisper_private], entries.map(&:command)
    assert_equal %w[start stop], entries.select(&:administrators_only).map(&:command)
    assert entries.all?(&:ephemeral), "every command is invisible to the group"
  end

  def test_default_payload_shape_is_the_members_menu
    payload = PrismHubot::CommandMenu.telegram_commands

    assert_equal %w[whisper whisper_private], payload.map { _1["command"] }
    assert_equal %w[command description is_ephemeral], payload.first.keys
    assert(payload.all? { _1["is_ephemeral"] })
  end

  def test_menus_per_scope_show_start_and_stop_to_administrators_only
    menus = PrismHubot::CommandMenu.telegram_menus.to_h { [_1.fetch("scope").fetch("type"), _1.fetch("commands").map { |c| c["command"] }] }

    assert_equal %w[whisper whisper_private], menus.fetch("default")
    assert_equal %w[start stop whisper whisper_private], menus.fetch("all_chat_administrators")
    assert_equal [], menus.fetch("all_private_chats"), "Whisper reads groups: private chats get no menu"
    refute_includes menus.fetch("default"), "start"
  end

  def test_every_command_in_the_menu_is_declared_ephemeral
    PrismHubot::CommandMenu.telegram_menus.flat_map { _1.fetch("commands") }.each do |command|
      assert_equal true, command["is_ephemeral"], command["command"]
    end
  end
end
