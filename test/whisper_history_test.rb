# © 2026 aiaiaiai · aiaiaiai.org

require "minitest/autorun"
require_relative "../lib/prism_hubot/whisper/history"

class WhisperHistoryTest < Minitest::Test
  def setup
    @now = 100_000
    @history = PrismHubot::Whisper::History.new(clock: -> { @now })
    @surface = {chat_id: -100, topic_id: 7}
  end

  def observe(id, author: 1, username: "one", text: "message #{id}", revision: id,
    timestamp: @now, label: "User #{author}", **surface)
    @history.observe(**@surface.merge(surface), id:, revision:, timestamp:,
      author_id: author, label:, username:, text:)
  end

  def snapshot(**options)
    @history.snapshot(**@surface, actor: 9, **options)
  end

  def select(snap, **options)
    @history.select(snap, **@surface, actor: 9, **options)
  end

  def test_disabled_history_is_not_collected_and_reenable_invalidates_snapshot
    refute observe(1)
    @history.enable(**@surface)
    assert observe(2)
    snap = snapshot
    @history.disable(**@surface)
    @history.enable(**@surface)
    assert_raises(PrismHubot::Whisper::Refusal) { select(snap, anchor: 2) }
    assert_raises(PrismHubot::Whisper::Refusal) { snapshot }
  end

  def test_fixed_snapshot_author_union_and_chronological_range
    @history.enable(**@surface)
    observe(3, author: 2, username: "two")
    observe(1)
    observe(2, author: 3, username: "three")
    snap = snapshot(usernames: ["@ONE", "@two"])
    observe(4)
    entries = select(snap, anchor: 1)
    assert_equal [1, 3], entries.map(&:id)
    assert_equal "User 1: message 1\nUser 2: message 3", @history.narrate(entries)
    assert_equal [1, 3], select(snap, anchor: 3, backward_count: 2).map(&:id)
    assert_raises(PrismHubot::Whisper::Refusal) { select(snap, anchor: 3, backward_count: 3) }
  end

  def test_actor_and_topic_isolation
    @history.enable(**@surface)
    @history.enable(chat_id: -100, topic_id: 8)
    observe(1)
    observe(2, topic_id: 8)
    snap = snapshot
    assert_equal [1], select(snap, anchor: 1).map(&:id)
    assert_raises(PrismHubot::Whisper::Refusal) do
      @history.select(snap, **@surface, actor: 10, anchor: 1)
    end
    assert_raises(PrismHubot::Whisper::Refusal) do
      @history.select(snap, chat_id: -100, topic_id: 8, actor: 9, anchor: 1)
    end
  end

  def test_edit_and_delete_invalidate_without_replay
    @history.enable(**@surface)
    observe(1)
    snap = snapshot
    refute observe(1)
    assert observe(1, revision: 2, text: "edited")
    assert_raises(PrismHubot::Whisper::Refusal) { select(snap, anchor: 1) }
    updated = snapshot
    @history.forget(**@surface, id: 1)
    refute observe(1, revision: 3)
    assert_raises(PrismHubot::Whisper::Refusal) { select(updated, anchor: 1) }
  end

  def test_retention_count_age_and_no_silent_truncation
    @history.enable(**@surface)
    101.times { |i| observe(i + 1) }
    snap = snapshot
    assert_equal 100, @history.picker(snap, **@surface, actor: 9).size
    refute observe(1, revision: 999)
    assert_raises(PrismHubot::Whisper::Refusal) { select(snap, anchor: 2) }
    assert_raises(PrismHubot::Whisper::Refusal) { select(snap, anchor: 80, screen: true) }
    assert_equal 20, select(snap, anchor: 82, screen: true).size
    @now += 86_400
    assert_raises(PrismHubot::Whisper::Refusal) { snapshot }
  end

  def test_ambiguous_handle_and_character_cap
    @history.enable(**@surface)
    observe(1, text: "x" * 4_096)
    observe(2, author: 2)
    assert_raises(PrismHubot::Whisper::Refusal) { snapshot(usernames: ["one"]) }
    assert_raises(PrismHubot::Whisper::Refusal) { select(snapshot, anchor: 1) }
  end

  def test_messages_sent_before_enable_stay_ineligible_even_when_edited_later
    @history.enable(**@surface)
    refute observe(1, timestamp: @now - 1)
    assert observe(2)
    assert_raises(PrismHubot::Whisper::Refusal) { select(snapshot(usernames: ["one"]), anchor: 1) }
  end

  def test_text_beyond_telegram_limit_is_not_retained
    @history.enable(**@surface)
    refute observe(1, text: "x" * 4_097)
    assert observe(2, text: "x" * 4_096)
  end

  def test_labels_with_control_or_invisible_characters_are_rejected
    @history.enable(**@surface)
    ["Ann\nBob", "Ann\u202EBob", "Ann\u200BBob"].each_with_index do |label, index|
      refute observe(index + 1, label:)
    end
    assert observe(10, label: "Ann Bob")
  end

  def test_tombstone_overflow_disables_surface_with_a_distinct_refusal
    @history.enable(**@surface)
    assert observe(1)
    201.times { |i| @history.forget(**@surface, id: i + 1) }
    refute observe(500)
    error = assert_raises(PrismHubot::Whisper::Refusal) { snapshot }
    assert_equal "disabled_overflow", error.message
    @history.enable(**@surface)
    assert observe(600)
    assert_equal [600], @history.picker(snapshot, **@surface, actor: 9).map(&:id)
  end

  def test_disabled_surface_reports_not_enabled
    error = assert_raises(PrismHubot::Whisper::Refusal) { snapshot }
    assert_equal "not_enabled", error.message
  end
end
