class ApplicationController < ActionController::API
  include ActionController::Cookies

  COOKIE = :pb_session

  before_action :require_json!

  # SEC-02: a general per-user limit (per IP when anonymous). Endpoint-specific limits are declared in each controller.
  rate_limit to: 600, within: 1.minute, name: "general", by: -> { limit_key }, with: -> { rate_limited!(60) }

  # Declared first so every more specific handler below takes precedence (Rails checks last-declared first).
  rescue_from StandardError do |e|
    Rails.logger.error("#{e.class}: #{e.message}\n#{e.backtrace&.first(10)&.join("\n")}")
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
  def limit_key = current_user ? "user:#{current_user.id}" : "ip:#{request.remote_ip}"

  def audit(event, user: current_user, **meta)
    AuditEvent.record(event, user: user, ip: request.remote_ip, user_agent: request.user_agent, **meta)
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
    session = user.sessions.create!(user_agent: request.user_agent&.first(255), ip_address: request.remote_ip)
    cookies.signed[COOKIE] = { value: session.raw_token, httponly: true, same_site: :lax,
                               expires: Session::ABSOLUTE_LIFETIME.from_now, secure: Rails.env.production? }
    session
  end
end
