# © 2026 aiaiaiai · aiaiaiai.org

require "uri"

module PrismHubot
  module Speech
    # Where Whisper's speech path may send a request. https is always allowed. Cleartext http is
    # allowed only when the caller says the peer is on this server's private network AND the host is a
    # single label (a Docker network alias such as `prism-ai-tts`): such a name resolves only inside
    # that network, so the bearer token never crosses a public network in the clear. A dotted name,
    # an IP address or `localhost` is never accepted over http.
    module Endpoint
      SINGLE_LABEL = /\A[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\z/
      private_constant :SINGLE_LABEL

      def self.permitted?(uri, private_network: false)
        return false unless uri.is_a?(URI::Generic) && uri.host

        return true if uri.is_a?(URI::HTTPS)

        private_network && uri.is_a?(URI::HTTP) && SINGLE_LABEL.match?(uri.host) && uri.host != "localhost"
      end
    end
  end
end
