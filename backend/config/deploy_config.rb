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

  # OPS-05: connections the deployment can need must fit under the database's limit. Returns a message, or nil if fine.
  #   web:    WEB_PROCESSES x RAILS_MAX_THREADS      worker: every worker thread + dispatcher      plus 5 spare
  def pool_problem(env)
    limit = Integer(env.fetch("DB_POOL_LIMIT", 0))
    return nil if limit <= 0 # no declared limit, nothing to check
    web = Integer(env.fetch("WEB_PROCESSES", 1)) * Integer(env.fetch("RAILS_MAX_THREADS", 3))
    worker = Integer(env.fetch("JOB_CRITICAL_THREADS", 2)) + Integer(env.fetch("JOB_DEFAULT_THREADS", 3)) * Integer(env.fetch("JOB_CONCURRENCY", 1)) +
             Integer(env.fetch("JOB_LOW_THREADS", 1)) + 1
    need = web + worker + 5
    need > limit ? "database pool: need #{need} connections (web #{web} + worker #{worker} + 5) but DB_POOL_LIMIT is #{limit}" : nil
  end
end
