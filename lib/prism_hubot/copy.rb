# © 2026 aiaiaiai · aiaiaiai.org

module PrismHubot
  module Copy
    HELP = <<~TEXT.freeze
      Prism Hubot (Whisper):
      #{CommandMenu.help_lines}
    TEXT

    # Every private Whisper message states its audience; a public one never claims to be private.
    PRIVATE = "🔒 Приватно · Whisper".freeze

    # The audience of a result everyone in the group can hear. It never claims to be private.
    PUBLIC = "🔓 Для всіх · Whisper".freeze

    WHISPER_PUBLIC_HINT = "Whisper працює приватно. Надішліть цю команду з меню команд бота: так її не побачить " \
      "група.".freeze
    WHISPER_NOT_A_GROUP = "#{PRIVATE}\nWhisper читає повідомлення груп. Додайте мене в групу, зробіть " \
      "адміністратором і надішліть там /start.".freeze
    WHISPER_NOT_ENABLED = "#{PRIVATE}\nWhisper у цій групі ще не запущено. Адміністратор вмикає його командою " \
      "/start.".freeze
    WHISPER_OVERFLOW = "#{PRIVATE}\nWhisper зупинено: забагато видалених повідомлень, щоб гарантувати " \
      "їх забування. Адміністратор може увімкнути його знову командою /start.".freeze
    WHISPER_BOT_NOT_ADMIN = "#{PRIVATE}\nЩоб увімкнути Whisper, бот має бути адміністратором групи " \
      "(так він бачить повідомлення й може відповідати приватно). Зробіть його адміністратором і надішліть " \
      "/start ще раз.".freeze
    WHISPER_NOT_ADMIN = "#{PRIVATE}\nЦе може зробити лише адміністратор групи.".freeze
    WHISPER_UNCONFIRMED = "#{PRIVATE}\nНе вдалося підтвердити ваші права в цій групі. Нічого не змінено.".freeze
    WHISPER_ENABLED = "#{PRIVATE}\nWhisper увімкнено. Про це повідомлено в групі.".freeze
    WHISPER_ALREADY_ON = "#{PRIVATE}\nWhisper у цій групі вже увімкнено.".freeze
    WHISPER_ALREADY_OFF = "#{PRIVATE}\nWhisper у цій групі й так вимкнено.".freeze
    WHISPER_DISABLED = "#{PRIVATE}\nWhisper вимкнено, збережені тексти видалено.".freeze
    WHISPER_CAPACITY = "#{PRIVATE}\nБот уже обслуговує максимум груп для Whisper. Нічого не змінено.".freeze
    WHISPER_NOT_DISCLOSED = "#{PRIVATE}\nНе вдалося повідомити групу про збереження текстів. " \
      "Whisper не увімкнено.".freeze

    # Public, on purpose: members must be able to see that their messages are being kept.
    WHISPER_ANNOUNCE_ON = "ℹ️ Whisper увімкнено адміністратором для цієї групи. Бот тимчасово зберігає " \
      "тексти нових повідомлень (до 100 останніх, до 24 годин, у пам'яті) для голосового прочитання на " \
      "прохання учасників. Адміністратор вимикає: /stop.".freeze
    WHISPER_ANNOUNCE_OFF = "ℹ️ Whisper вимкнено, збережені тексти повідомлень видалено.".freeze

    WHISPER_PICK = "Оберіть повідомлення, з якого почати: прочитається воно й усі новіші до кінця вибору.".freeze
    WHISPER_USAGE = "#{PRIVATE}\nФормат: /whisper (або /whisper_private) і за потреби @автор, @автор1 @автор2, " \
      "5 (останні 5) або екран.".freeze
    WHISPER_PICKER_CLOSED = "#{PRIVATE}\nВибір закрито.".freeze
    WHISPER_PICKER_STALE = "#{PRIVATE}\nСписок застарів або змінився. Викличте команду ще раз.".freeze
    WHISPER_CHOSEN = "#{PRIVATE}\nВибрано %<count>d повідомлень (%<characters>d символів). " \
      "Озвучення поки недоступне.".freeze
    WHISPER_CHOSEN_SPEAKING = "#{PRIVATE}\nВибрано %<count>d повідомлень (%<characters>d символів). Озвучую…".freeze
    WHISPER_CHOSEN_SPEAKING_PUBLIC = "#{PRIVATE}\nВибрано %<count>d повідомлень (%<characters>d символів). " \
      "Озвучую для всіх…".freeze
    WHISPER_VOICE_DONE = "#{PRIVATE}\nГотово: голос надіслано лише вам.".freeze
    WHISPER_VOICE_DONE_PUBLIC = "#{PRIVATE}\nГотово: голос надіслано в групу.".freeze
    WHISPER_VOICE_BUSY = "#{PRIVATE}\nВи вже озвучуєте повідомлення, або бот зайнятий. Спробуйте за хвилину.".freeze
    WHISPER_VOICE_NOT_DELIVERED = "#{PRIVATE}\nГолос готовий, але Telegram не дозволив надіслати його приватно, " \
      "тож нічого не надіслано.".freeze
    WHISPER_VOICE_NOT_DELIVERED_PUBLIC = "#{PRIVATE}\nГолос готовий, але Telegram не дозволив надіслати його " \
      "в групу, тож нічого не надіслано.".freeze
    WHISPER_SPEECH_FAILURES = {
      unavailable: "#{PRIVATE}\nОзвучення зараз недоступне. Спробуйте пізніше.",
      busy: "#{PRIVATE}\nСервіс озвучення зайнятий. Спробуйте за хвилину.",
      too_long: "#{PRIVATE}\nВибір завеликий для озвучення. Оберіть менше повідомлень.",
      rejected: "#{PRIVATE}\nСервіс озвучення відхилив запит. Нічого не надіслано.",
      timeout: "#{PRIVATE}\nОзвучення зайняло надто багато часу. Спробуйте менше повідомлень.",
      encoding: "#{PRIVATE}\nНе вдалося підготувати голос. Нічого не надіслано."
    }.each_value(&:freeze).freeze
    WHISPER_REFUSALS = {
      "history_unavailable" => "Немає збережених повідомлень, які можна прочитати. Whisper бачить лише те, що надійшло після його вмикання.",
      "unresolved_author" => "Не вдалося однозначно визначити автора за цим іменем серед збережених повідомлень.",
      "invalid_filter" => "Некоректний фільтр авторів.",
      "range_limit" => "Вибір завеликий для одного озвучення (до 50 повідомлень і 4000 символів). Оберіть пізніше повідомлення або менший діапазон.",
      "anchor_unavailable" => "Цього повідомлення вже немає в списку.",
      "stale_snapshot" => "Список застарів або змінився. Викличте команду ще раз.",
      "invalid_snapshot" => "Список застарів або змінився. Викличте команду ще раз.",
      "disabled_overflow" => WHISPER_OVERFLOW.delete_prefix("#{PRIVATE}\n"),
      "not_enabled" => "Whisper у цій групі ще не запущено. Адміністратор вмикає його командою /start."
    }.freeze
    WHISPER_REFUSAL_FALLBACK = "Whisper не зміг виконати запит. Нічого не змінено.".freeze

    WHISPER_CANCEL_BUTTON = "Скасувати".freeze
  end
end
