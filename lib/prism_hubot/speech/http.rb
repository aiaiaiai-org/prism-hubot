# © 2026 aiaiaiai · aiaiaiai.org

require "net/http"
require "uri"

module PrismHubot
  module Speech
    # One bounded request: no redirects, HTTPS (cleartext only to a private-network alias, see Endpoint),
    # a size cap on the answer, and timeouts.
    # It is the only place in Whisper's speech path that touches the network, and it never logs.
    class Http
      Response = Data.define(:status, :body)

      def initialize(open_timeout: 5, read_timeout: 90)
        @open_timeout = open_timeout
        @read_timeout = read_timeout
      end

      def post(url, headers:, body:, max_bytes:, private_network: false)
        uri = URI(url)
        raise Failure.new(:unavailable) unless Endpoint.permitted?(uri, private_network: private_network)

        request = Net::HTTP::Post.new(uri)
        headers.each { |name, value| request[name] = value }
        request.body = body
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.is_a?(URI::HTTPS), open_timeout: @open_timeout,
          read_timeout: @read_timeout) do |http|
          http.request(request) do |response|
            return Response.new(status: response.code.to_i, body: read_limited(response, max_bytes))
          end
        end
      rescue Net::OpenTimeout, Net::ReadTimeout
        raise Failure.new(:timeout)
      rescue SystemCallError, SocketError, IOError, OpenSSL::SSL::SSLError, Net::ProtocolError
        raise Failure.new(:unavailable)
      end

      private

      def read_limited(response, max_bytes)
        body = String.new(encoding: Encoding::BINARY)
        response.read_body do |chunk|
          body << chunk
          raise Failure.new(:rejected) if body.bytesize > max_bytes
        end
        body
      end
    end
  end
end
