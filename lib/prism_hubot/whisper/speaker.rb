# © 2026 aiaiaiai · aiaiaiai.org

module PrismHubot
  module Whisper
    # Turns a chosen range into a private voice message, in the background. Everything the person
    # hears about it goes into the one status message their button press sits on, by editing it; the
    # finished voice is sent to them alone. Nothing here ever falls back to a public message: when a
    # private delivery or edit is not possible, it is logged without content and nothing is sent.
    #
    # A person has at most one voice in progress per chat and topic, and the pool is bounded, so a
    # button pressed repeatedly cannot queue unlimited synthesis.
    class Speaker
      def initialize(voice:, voice_sender:, responder:, executor: ThreadExecutor.new, logger: Logger.new($stderr))
        @voice = voice
        @voice_sender = voice_sender
        @responder = responder
        @executor = executor
        @logger = logger
        @mutex = Mutex.new
        @running = {}
      end

      # :started once the work is accepted, :busy if this person already has a voice in progress or
      # the pool is full. The block runs after the slot is claimed and before the work can finish, so
      # the "in progress" status can never overwrite the final one.
      def start(update, text)
        key = key(update)
        return :busy unless claim(key)

        begin
          yield if block_given?
        rescue
          release(key)
          raise
        end
        accepted = @executor.post do
          run(update, text)
        ensure
          release(key)
        end
        return :started if accepted

        release(key)
        :busy
      end

      private

      def run(update, text)
        clip = @voice.call(text)
        @voice_sender.send_ephemeral_voice(target: target(update), clip: clip, caption: Copy::PRIVATE)
        finish(update, Copy::WHISPER_VOICE_DONE)
      rescue Speech::Failure => failure
        @logger.warn("whisper_speech failed code=#{failure.code}")
        finish(update, Copy::WHISPER_SPEECH_FAILURES.fetch(failure.code))
      rescue PrismBot::Error => error
        @logger.warn("whisper_speech not_delivered code=#{error.code}")
        finish(update, Copy::WHISPER_VOICE_NOT_DELIVERED)
      rescue => error
        @logger.error("whisper_speech unexpected_error class=#{error.class.name}")
        finish(update, Copy::WHISPER_REFUSAL_FALLBACK)
      end

      # The status can only be edited privately; if that fails the person simply sees the old status.
      def finish(update, text)
        @responder.settle_private(update, text)
      rescue PrismBot::Error => error
        @logger.warn("whisper_speech status_not_updated code=#{error.code}")
      end

      # The bot is an administrator here (Whisper cannot be on otherwise), which is what lets it
      # address a member after the 15 seconds a button press entitles it to.
      def target(update)
        PrismBot::Domain::EphemeralTarget.to_member(
          chat_id: update.chat_id, receiver_user_id: update.user_id,
          message_thread_id: update.surface_context.message_thread_id
        )
      end

      def key(update)
        [update.chat_id, update.surface_context.message_thread_id, update.user_id]
      end

      def claim(key)
        @mutex.synchronize do
          return false if @running[key]

          @running[key] = true
        end
      end

      def release(key)
        @mutex.synchronize { @running.delete(key) }
      end
    end
  end
end
