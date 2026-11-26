class ApplicationController < ActionController::API
  include ActionController::Cookies

  COOKIE = :pb_session

  before_action :require_json!
  before_action { response.headers["Cache-Control"] = "private, no-store" } # SCL-13: per-user by default

  # SEC-02: a general per-user limit (per IP when anonymous). Endpoint-specific limits are declared in each controller.
  rate_limit to: 600, within: 1.minute, name: "general", by: -> { limit_key }, with: -> { rate_limited!(60) }

  # Declared first so every more specific handler below takes precedence (Rails checks last-declared first).
  rescue_from StandardError do |e|
    Rails.logger.error("#{e.class}: #{e.message}\n#{e.backtrace&.first(10)&.join("\n")}")
    # OBS-01: hand the exception to whatever error tracker is subscribed (Rails.error), with ids only, never emails.
    Rails.error.report(e, handled: true, severity: :error, source: "api",
                       context: { request_id: request.request_id, user_id: current_user&.id, route: "#{request.method} #{request.path}" })
    render json: { error: { code: "internal", message: "Something went wrong. Please try again." } }, status: 500
  end
  rescue_from ActionDispatch::Http::Parameters::ParseError do
    render_error(:validation_failed, "Request body is not valid JSON")
  end
  rescue_from ApiError do |e|
    render json: { error: { code: e.code, message: e.message }.merge(e.details.present? ? { details: e.details } : {}) },
           status: e.status
  end
  rescue_from ActiveRecord::RecordNotFound do
    render_error(:not_found, "Not found")
  end
  rescue_from ActiveRecord::RecordInvalid do |e|
    render_error(:validation_failed, e.record.errors.full_messages.to_sentence)
  end
  rescue_from ActionController::ParameterMissing do |e|
    render_error(:validation_failed, e.message)
  end

  private

  # SCL-13: shared market data (status, overview, candles) may be cached by browsers and CDNs. ETags come from
  # Rack::ETag, so a repeat request with If-None-Match gets a 304 without a body.
  def cache_publicly(seconds)
    response.headers["Cache-Control"] = "public, max-age=#{seconds}"
  end

  # AUTH-06 (CSRF defense): state-changing requests must be JSON. DELETEs must accept JSON and,
  # when the browser sends an Origin, it must be ours.
  def require_json!
    return if request.get? || request.head?
    if request.delete?
      ok = request.headers["Accept"].to_s.include?("application/json") && origin_allowed?
    else
      ok = request.media_type == "application/json"
    end
    raise ApiError.new(:unsupported_media_type, "Requests must be JSON (Content-Type: application/json).") unless ok
  end

  def origin_allowed?
    origin = request.headers["Origin"]
    return true if origin.blank?
    allowed = ENV.fetch("ALLOWED_ORIGINS", "http://localhost:5173").split(",").map(&:strip) + [ request.base_url ]
    allowed.include?(origin)
  end

  def rate_limited!(retry_after = 60)
    response.set_header("Retry-After", retry_after.to_i.to_s)
    render json: { error: { code: "rate_limited", message: "Too many attempts. Please wait a few minutes and try again." } },
           status: :too_many_requests
  end

  # Signed-in users are limited per user, everyone else per client IP (SEC-01 makes that the real client).
  def limit_key = current_user ? "user:#{current_user.id}" : "ip:#{client_ip}"

  # SEC-01: Rails' remote_ip believes X-Forwarded-For even when the direct peer is not a proxy, so a client could pick
  # its own IP. Only honour the header when the connecting peer is a trusted proxy.
  def client_ip
    proxies = Rails.application.config.action_dispatch.trusted_proxies || ActionDispatch::RemoteIp::TRUSTED_PROXIES
    peer = IPAddr.new(request.remote_addr.to_s) rescue nil
    peer && proxies.any? { |p| p.include?(peer) } ? request.remote_ip : request.remote_addr
  end

  def audit(event, user: current_user, **meta)
    AuditEvent.record(event, user: user, ip: client_ip, user_agent: request.user_agent, **meta)
  end

  def render_error(code, message)
    err = ApiError.new(code, message)
    render json: { error: { code: err.code, message: err.message } }, status: err.status
  end

  def current_session
    return @current_session if defined?(@current_session)
    found = Session.includes(user: :account).find_by_token(cookies.signed[COOKIE])
    if found&.expired? # SES-02
      found.destroy
      found = nil
    end
    found&.touch_seen!
    @current_session = found
  end

  def current_user = current_session&.user
  def current_account = current_user&.account

  def authenticate!
    raise ApiError.new(:unauthenticated, "Please sign in to continue.") unless current_user && !current_user.deleted?
    raise ApiError.new(:account_disabled, "This account has been disabled. Contact support.") if current_user.disabled? # ADM-02
  end

  def start_session!(user)
    session = user.sessions.create!(user_agent: request.user_agent&.first(255), ip_address: client_ip)
    cookies.signed[COOKIE] = { value: session.raw_token, httponly: true, same_site: :lax,
                               expires: Session::ABSOLUTE_LIFETIME.from_now, secure: Rails.env.production? }
    session
  end
end
