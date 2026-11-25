require "ipaddr"

# Pure helpers for environment-driven deployment settings (SEC-01, SEC-06), kept out of the Rails config files so
# they can be unit-tested.
module DeployConfig
  module_function

  # Parses "10.1.0.0/16, 203.0.113.5" into IPAddr objects plus Rails' default private ranges. nil when unset.
  def trusted_proxies(value)
    return nil if value.to_s.strip.empty?
    extra = value.split(",").map(&:strip).reject(&:empty?).map { |cidr| IPAddr.new(cidr) }
    require "action_dispatch/middleware/remote_ip"
    ActionDispatch::RemoteIp::TRUSTED_PROXIES + extra
  end

  # "app.example.com, .example.org" -> host patterns for config.hosts. nil when unset (hosts unrestricted).
  def hosts(value)
    list = value.to_s.split(",").map(&:strip).reject(&:empty?)
    list.empty? ? nil : list
  end
end
