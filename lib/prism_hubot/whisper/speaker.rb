# © 2026 aiaiaiai · aiaiaiai.org

module PrismHubot
  module Whisper
    # Turns a chosen range into a voice message, in the background. Everything the person hears about
    # it goes into the one private status message their button press sits on, by editing it. The
    # finished voice goes to them alone (:private) or, only when they asked with /whisper, to the group
    # they chose it in (:public, labelled as for everyone). A private result is never made public: when a
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
      # authors are the display labels of those whose messages are in text, for the voice's caption.
      def start(update, text, visibility: :private, authors: [])
        key = key(update)
        return :busy unless claim(key)

        begin
          yield if block_given?
        rescue
          release(key)
          raise
        end
        accepted = @executor.post do
          run(update, text, visibility, authors)
        ensure
          release(key)
        end
        return :started if accepted

        release(key)
        :busy
      end

      private

      def run(update, text, visibility, authors)
        clip = @voice.call(text)
        deliver(update, clip, visibility, authors)
        replace_status(update, (visibility == :public) ? Copy::WHISPER_VOICE_DONE_PUBLIC : Copy::WHISPER_VOICE_DONE)
      rescue Speech::Failure => failure
        @logger.warn("whisper_speech failed code=#{failure.code}")
        finish(update, Copy::WHISPER_SPEECH_FAILURES.fetch(failure.code))
      rescue PrismBot::Error => error
        @logger.warn("whisper_speech not_delivered code=#{error.code}")
        finish(update, (visibility == :public) ? Copy::WHISPER_VOICE_NOT_DELIVERED_PUBLIC : Copy::WHISPER_VOICE_NOT_DELIVERED)
      rescue => error
        @logger.error("whisper_speech unexpected_error class=#{error.class.name}")
        finish(update, Copy::WHISPER_REFUSAL_FALLBACK)
      end

      def deliver(update, clip, visibility, authors)
        if visibility == :public
          @voice_sender.send_public_voice(
            chat_id: update.chat_id, clip: clip, caption: Caption.build(Copy::PUBLIC, authors),
            message_thread_id: update.surface_context.message_thread_id
          )
        else
          @voice_sender.send_ephemeral_voice(target: target(update), clip: clip, caption: Caption.build(Copy::PRIVATE, authors))
        end
      end

      # The voice has been delivered, so the "in progress" status has done its job: it is removed, and
      # the voice stands in its place. If it cannot be removed it says it is done instead.
      def replace_status(update, done_text)
        return if @responder.remove_status(update)

        finish(update, done_text)
      rescue PrismBot::Error => error
        @logger.warn("whisper_speech status_not_removed code=#{error.code}")
        finish(update, done_text)
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
