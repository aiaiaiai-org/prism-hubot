# © 2026 aiaiaiai · aiaiaiai.org

module PrismHubot
  # Reads an environment file the way systemd reads `EnvironmentFile=`, the
  # format the earlier systemd deployment used; local rake tasks still read
  # `.env` through it.
  #
  # Deployment tasks used to read the same file with `bash`, but `source` is
  # not a parser: it executes what it reads. `TOKEN=<from-botfather>` is a
  # redirection, `SECRET=a|b` is a pipeline, `URL=$(cat /etc/shadow)` is a
  # command substitution. A file the service starts from perfectly well can
  # therefore abort a deployment with `syntax error near unexpected token`.
  # Reading it here keeps one reading of the file and never executes it.
  #
  # Supported syntax, as documented for `EnvironmentFile=`:
  #
  # - `NAME=value`, one assignment per line;
  # - blank lines, and comments introduced by `#` or `;` in the first
  #   non-blank column;
  # - single- and double-quoted values, which may span lines and may hold
  #   whitespace, `#` and shell metacharacters verbatim;
  # - `\` escapes the next character, and `\` at end of line continues the
  #   assignment (or the comment) on the following line;
  # - trailing whitespace of an unquoted value is dropped.
  #
  # There is no variable expansion, no command substitution and no `export`
  # keyword, because systemd has none of them. Lines that are not valid
  # assignments are reported to `on_warning` and skipped rather than raised
  # on: systemd ignores them too, and a reader that rejected a file the
  # service happily starts from would just move the disagreement elsewhere.
  module EnvFile
    NAME_PATTERN = /\A[A-Za-z_][A-Za-z0-9_]*\z/
    COMMENT_CHARACTERS = "#;".freeze
    WHITESPACE = " \t\r".freeze
    MAX_BYTES = 1_048_576
    MAX_REPORTED_NAME_LENGTH = 64

    # Character-by-character transcription of systemd's env-file states, so
    # that quoting, escaping and continuation behave the same on both sides.
    class Parser
      def initialize(source, on_warning: nil)
        @source = String(source)
        @on_warning = on_warning
        @variables = {}
        @state = :pre_key
        @name = +""
        @value = +""
        @whitespace = +""
        @line = 1
        @name_line = 1
      end

      def call
        @source.each_char { consume(_1) }
        finish
        @variables
      end

      private

      def consume(character)
        case @state
        when :pre_key then pre_key(character)
        when :key then key(character)
        when :pre_value then pre_value(character)
        when :value then value(character)
        when :value_escape then value_escape(character)
        when :single_quote then single_quote(character)
        when :single_quote_escape then single_quote_escape(character)
        when :double_quote then double_quote(character)
        when :double_quote_escape then double_quote_escape(character)
        when :comment then comment(character)
        when :comment_escape then comment_escape(character)
        end
        @line += 1 if character == "\n"
      end

      def pre_key(character)
        return if character == "\n" || WHITESPACE.include?(character)

        if COMMENT_CHARACTERS.include?(character)
          @state = :comment
        else
          @state = :key
          @name = character.dup
          @name_line = @line
        end
      end

      def key(character)
        case character
        when "\n"
          report("line #{@name_line}: ignoring a line without `=`")
          reset
        when "="
          @state = :pre_value
        else
          @name << character
        end
      end

      def pre_value(character)
        case character
        when "\n" then assign
        when "'" then @state = :single_quote
        when "\"" then @state = :double_quote
        when "\\" then @state = :value_escape
        else
          unless WHITESPACE.include?(character)
            @value << character
            @state = :value
          end
        end
      end

      def value(character)
        case character
        when "\n" then assign
        when "'" then quoted(:single_quote)
        when "\"" then quoted(:double_quote)
        when "\\" then @state = :value_escape
        else
          if WHITESPACE.include?(character)
            @whitespace << character
          else
            absorb_whitespace
            @value << character
          end
        end
      end

      # A `\` at end of line continues the value on the next line; anything
      # else is taken literally, brackets and metacharacters included.
      def value_escape(character)
        @state = :value
        return if character == "\n"

        absorb_whitespace
        @value << character
      end

      def single_quote(character)
        case character
        when "'" then @state = :pre_value
        when "\\" then @state = :single_quote_escape
        else @value << character
        end
      end

      def single_quote_escape(character)
        @state = :single_quote
        @value << character unless character == "\n"
      end

      def double_quote(character)
        case character
        when "\"" then @state = :pre_value
        when "\\" then @state = :double_quote_escape
        else @value << character
        end
      end

      def double_quote_escape(character)
        @state = :double_quote
        @value << character unless character == "\n"
      end

      def comment(character)
        case character
        when "\\" then @state = :comment_escape
        when "\n" then reset
        end
      end

      def comment_escape(_character)
        @state = :comment
      end

      def finish
        case @state
        when :pre_value, :value, :value_escape
          assign
        when :key
          report("line #{@name_line}: ignoring a line without `=`")
        when :single_quote, :single_quote_escape, :double_quote, :double_quote_escape
          report("line #{@name_line}: ignoring #{reportable_name}, its quoted value is never closed")
        end
      end

      def quoted(state)
        absorb_whitespace
        @state = state
      end

      # Whitespace inside a value is only kept once something follows it, so a
      # value's trailing whitespace never reaches the variable.
      def absorb_whitespace
        return if @whitespace.empty?

        @value << @whitespace
        @whitespace = +""
      end

      def assign
        if @name.match?(NAME_PATTERN)
          @variables[@name] = @value.dup
        else
          report_invalid_name
        end
        reset
      end

      def reset
        @state = :pre_key
        @name = +""
        @value = +""
        @whitespace = +""
      end

      def report_invalid_name
        stripped = @name.strip
        keyword, _, remainder = stripped.partition(" ")
        if stripped.match?(NAME_PATTERN)
          report("line #{@name_line}: ignoring `#{stripped}`, systemd allows no whitespace around `=`")
        elsif keyword == "export" && remainder.match?(NAME_PATTERN)
          report("line #{@name_line}: ignoring `#{remainder}`, `export` is a shell keyword systemd does not read")
        else
          report("line #{@name_line}: ignoring the invalid variable name #{reportable_name}")
        end
      end

      def reportable_name
        name = @name.length > MAX_REPORTED_NAME_LENGTH ? "#{@name[0, MAX_REPORTED_NAME_LENGTH]}…" : @name
        "`#{name}`"
      end

      def report(message)
        @on_warning&.call(message)
      end
    end

    module_function

    # Parses `source` and returns the variables systemd would export from it.
    def parse(source, on_warning: nil)
      Parser.new(source, on_warning: on_warning).call
    end

    # Same, for a file. Warnings are prefixed with the path, so an operator
    # gets the same line numbers `bash` used to shout about.
    def read(path, on_warning: nil)
      source = File.read(path, MAX_BYTES + 1)
      if source.bytesize > MAX_BYTES
        raise ArgumentError, "#{path} is larger than #{MAX_BYTES} bytes"
      end

      parse(
        source.force_encoding(Encoding::UTF_8),
        on_warning: on_warning && ->(message) { on_warning.call("#{path}: #{message}") }
      )
    end

    # Sets every variable the file defines that `environment` does not define
    # already, so an explicit `NAME=value bundle exec rake …` still wins.
    # Returns the names it set; values are never returned or logged.
    def apply!(path, environment: ENV, on_warning: nil)
      on_warning ||= ->(message) { warn(message) }
      applied = []
      read(path, on_warning: on_warning).each do |name, value|
        next if environment.key?(name)

        environment[name] = value
        applied << name
      end
      applied.sort
    end
  end
end
