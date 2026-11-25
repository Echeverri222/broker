require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
# require "active_storage/engine"
require "action_controller/railtie"
# require "action_mailer/railtie"
# require "action_mailbox/engine"
# require "action_text/engine"
require "action_view/railtie"
require "action_mailer/railtie"
require_relative "deploy_config"
# require "action_cable/engine"
# require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Backend
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # Only loads a smaller set of middleware suitable for API only apps.
    # Middleware like session, flash, cookies can be added back manually.
    # Skip views, helpers and assets when generating a new resource.
    config.api_only = true
    config.middleware.use ActionDispatch::Cookies
    config.autoload_lib(ignore: %w[assets tasks]) if config.respond_to?(:autoload_lib)
    config.time_zone = "UTC"

    # SEC-01: behind a load balancer with a public address, trust its X-Forwarded-For so rate limits and the session
    # IP use the real client. TRUSTED_PROXIES is a comma-separated list of CIDRs; private ranges are always trusted.
    proxies = DeployConfig.trusted_proxies(ENV["TRUSTED_PROXIES"])
    config.action_dispatch.trusted_proxies = proxies if proxies

    # SEC-07: headers on every API response. The SPA's own CSP is set by the static host (deploy/nginx.conf).
    config.action_dispatch.default_headers = {
      "X-Content-Type-Options" => "nosniff",
      "X-Frame-Options" => "DENY",
      "Referrer-Policy" => "strict-origin-when-cross-origin",
      "Permissions-Policy" => "camera=(), microphone=(), geolocation=()",
      "Content-Security-Policy" => "default-src 'none'; frame-ancestors 'none'"
    }
  end
end
