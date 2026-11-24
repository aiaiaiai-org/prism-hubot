# © 2026 aiaiaiai · aiaiaiai.org

module PrismHubot
  module Copy
    HELP = <<~TEXT.freeze
      Prism Hubot:
      #{CommandMenu.help_lines}

      /publish текст — публікація у типові канали.
      /publish [channel-a,channel-b] текст — публікація у вибрані канали.
      Можна також написати «зробити допис» без команди.
    TEXT

    POST_PROMPT = "Надішли текст допису наступним повідомленням. /cancel — скасувати.".freeze
    EMPTY_POST = "Текст допису порожній. Надішли текст або /cancel.".freeze
    CANCELLED = "Поточну дію скасовано.".freeze

    # Every private Whisper message states its audience; a public one never claims to be private.
    PRIVATE = "🔒 Приватно · Whisper".freeze

    WHISPER_PUBLIC_HINT = "Whisper працює приватно. Надішліть /whisper як приватну команду " \
      "(оберіть її в меню команд бота).".freeze
    WHISPER_NOT_A_GROUP = "#{PRIVATE}\nWhisper читає повідомлення груп. Викличте /whisper у групі.".freeze
    WHISPER_READY = "#{PRIVATE}\nWhisper увімкнено для цієї групи. Вибір повідомлень з'явиться тут.".freeze
    WHISPER_NOT_ENABLED = "#{PRIVATE}\nWhisper у цій групі вимкнено. Увімкнути його може лише адміністратор групи.".freeze
    WHISPER_OVERFLOW = "#{PRIVATE}\nWhisper зупинено: забагато видалених повідомлень, щоб гарантувати " \
      "їх забування. Адміністратор може увімкнути його знову.".freeze
    WHISPER_BOT_NOT_ADMIN = "#{PRIVATE}\nЩоб увімкнути Whisper, бот має бути адміністратором групи " \
      "(так він бачить повідомлення й може відповідати приватно).".freeze
    WHISPER_NOT_ADMIN = "#{PRIVATE}\nЦе може зробити лише адміністратор групи.".freeze
    WHISPER_UNCONFIRMED = "#{PRIVATE}\nНе вдалося підтвердити ваші права в цій групі. Нічого не змінено.".freeze
    WHISPER_ENABLE_DISCLOSURE = "#{PRIVATE}\nУвімкнути Whisper для цієї групи?\n\n" \
      "Бот тимчасово зберігатиме в пам'яті тексти нових повідомлень (до 100 останніх і не довше 24 годин, " \
      "до перезапуску бота), щоб учасники могли приватно прослухати їх голосом. Ранішої історії бот не бачить. " \
      "Про це буде повідомлено в групі. Вимкнути: /whisper_off.".freeze
    WHISPER_ENABLED = "#{PRIVATE}\nWhisper увімкнено.".freeze
    WHISPER_CANCELLED = "#{PRIVATE}\nСкасовано. Whisper не увімкнено.".freeze
    WHISPER_ALREADY_OFF = "#{PRIVATE}\nWhisper у цій групі й так вимкнено.".freeze
    WHISPER_DISABLED = "#{PRIVATE}\nWhisper вимкнено, збережені тексти видалено.".freeze
    WHISPER_CAPACITY = "#{PRIVATE}\nБот уже обслуговує максимум груп для Whisper. Нічого не змінено.".freeze
    WHISPER_NOT_DISCLOSED = "#{PRIVATE}\nНе вдалося повідомити групу про збереження текстів. " \
      "Whisper не увімкнено.".freeze

    # Public, on purpose: members must be able to see that their messages are being kept.
    WHISPER_ANNOUNCE_ON = "ℹ️ Whisper увімкнено адміністратором для цієї групи. Бот тимчасово зберігає " \
      "тексти нових повідомлень (до 100 останніх, до 24 годин, у пам'яті) для голосового прочитання на " \
      "прохання учасників. Адміністратор вимикає: /whisper_off.".freeze
    WHISPER_ANNOUNCE_OFF = "ℹ️ Whisper вимкнено, збережені тексти повідомлень видалено.".freeze

    WHISPER_ENABLE_BUTTON = "Увімкнути".freeze
    WHISPER_CANCEL_BUTTON = "Скасувати".freeze
  end
end
