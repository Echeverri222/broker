require "net/http"
require "json"

module MarketData
  module Http
    UA = "Mozilla/5.0 (compatible; PaperBroker/0.1)".freeze

    def get_json(url, headers = {})
      uri = URI(url)
      Gateway.call(provider_name(uri)) { fetch_json(uri, headers) }
    end

    private

    def provider_name(uri) = uri.host.to_s.include?("coingecko") ? "coingecko" : "yahoo"

    def fetch_json(uri, headers)
      req = Net::HTTP::Get.new(uri, { "User-Agent" => UA, "Accept" => "application/json" }.merge(headers))
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 10) { |h| h.request(req) }
      raise ProviderError, "#{uri.host} responded #{res.code}" unless res.is_a?(Net::HTTPSuccess)
      JSON.parse(res.body)
    rescue JSON::ParserError, SocketError, Timeout::Error, SystemCallError, OpenSSL::SSL::SSLError, EOFError => e
      raise ProviderError, "#{uri&.host}: #{e.class}: #{e.message}"
    end
  end
end
