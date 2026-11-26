require "active_support/core_ext/integer/time"
require_relative "../json_log_formatter"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance and memory savings (ignored by Rake tasks).
  config.eager_load = true

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Cache assets for far-future expiry since they are all digest stamped.
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # Assume all access to the app is happening through a SSL-terminating reverse proxy.
  config.assume_ssl = ENV.fetch("ASSUME_SSL", "true") == "true"

  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  config.force_ssl = ENV.fetch("FORCE_SSL", "true") == "true"

  # Skip http-to-https redirect for the health checks, which load balancers call over plain HTTP.
  config.ssl_options = { redirect: { exclude: ->(request) { request.path.start_with?("/up") } } }

  # Log to STDOUT with the current request id as a default log tag.
  config.log_tags = [ :request_id ]
  config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT, formatter: JsonLogFormatter.new) # OBS-02

  # Change to "debug" to log everything (including potentially personally-identifiable information!).
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = "/up"

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Replace the default in-process memory cache store with a durable alternative.
  config.cache_store = :solid_cache_store

  # Replace the default in-process and non-durable queuing backend for Active Job.
  config.active_job.queue_adapter = :solid_queue
  config.solid_queue.connects_to = { database: { writing: :queue } }

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [ :id ]

  # SEC-06: only answer for our own host names (ALLOWED_HOSTS="app.example.com, .example.org"). Health checks are exempt.
  if (hosts = DeployConfig.hosts(ENV["ALLOWED_HOSTS"]))
    config.hosts = hosts
    config.host_authorization = { exclude: ->(request) { request.path.start_with?("/up") } }
  end

  # NTF-01: transactional mail over SMTP, configured only by environment variables (SEC-08).
  config.action_mailer.delivery_method = ENV["SMTP_ADDRESS"].present? ? :smtp : :test
  config.action_mailer.raise_delivery_errors = true # the job retries (JOB-04)
  if ENV["SMTP_ADDRESS"].present?
    config.action_mailer.smtp_settings = {
      address: ENV["SMTP_ADDRESS"], port: Integer(ENV.fetch("SMTP_PORT", 587)),
      user_name: ENV["SMTP_USER"], password: ENV["SMTP_PASSWORD"], authentication: :plain, enable_starttls_auto: true
    }
  end
end
