# © 2026 aiaiaiai · aiaiaiai.org

require_relative "test_helper"

class WhisperCaptionTest < Minitest::Test
  Caption = PrismHubot::Whisper::Caption
  PRIVATE = PrismHubot::Copy::PRIVATE

  def test_names_the_authors_after_the_audience_label
    assert_equal "#{PRIVATE}\nПовідомлення від: Ада, Борис", Caption.build(PRIVATE, %w[Ада Борис])
    assert_equal "#{PrismHubot::Copy::PUBLIC}\nПовідомлення від: Ада", Caption.build(PrismHubot::Copy::PUBLIC, %w[Ада])
  end

  def test_a_repeated_author_is_named_once_and_order_is_kept
    assert_equal "#{PRIVATE}\nПовідомлення від: Борис, Ада", Caption.build(PRIVATE, %w[Борис Ада Борис Ада])
  end

  def test_without_authors_it_is_just_the_label
    assert_equal PRIVATE, Caption.build(PRIVATE, [])
  end

  def test_a_long_list_is_counted_not_cut_mid_name_and_stays_within_telegrams_limit
    names = Array.new(40) { |index| "Дуже-Довге-Ім'я-Учасника-Групи-№#{index}-" + "я" * 40 }

    caption = Caption.build(PRIVATE, names)

    assert_operator caption.length, :<=, 1024
    assert caption.start_with?("#{PRIVATE}\nПовідомлення від: #{names.first}")
    assert_match(/ та ще \d+\z/, caption)
    shown = caption.delete_prefix("#{PRIVATE}\nПовідомлення від: ").sub(/ та ще \d+\z/, "").split(", ")
    assert_equal names.first(shown.size), shown, "only whole names, in order"
    assert_equal names.size - shown.size, caption[/\d+\z/].to_i
  end

  def test_the_label_always_comes_first_and_is_never_dropped
    assert Caption.build(PRIVATE, ["А" * 128] * 3).start_with?(PRIVATE)
  end
end
