# A cookie-keeping API client for examples that need several devices or users at the same time (SES-04, SEC-05).
# Contract validation lives in the request specs that use `api(...)`; this client is for behaviour.
class ApiClient
  HEADERS = { "CONTENT_TYPE" => "application/json", "ACCEPT" => "application/json" }.freeze
  attr_reader :email

  def initialize(ip: "127.0.0.1", agent: "RSpec")
    @s = ActionDispatch::Integration::Session.new(Rails.application)
    @ip = ip
    @agent = agent
  end

  def call(method, path, body = nil, headers = {})
    @s.send(method, "/api/v1#{path}", params: body && body.to_json,
            headers: HEADERS.merge("REMOTE_ADDR" => @ip, "HTTP_USER_AGENT" => @agent).merge(headers))
    self
  end

  def status = @s.response.status
  def body = @s.response.body
  def json = body.present? ? JSON.parse(body, symbolize_names: true) : nil
  def code = json&.dig(:error, :code)
  def header(name) = @s.response.headers[name]
  def cookie = @s.cookies["pb_session"]

  def sign_up(email: "u#{SecureRandom.hex(4)}@example.com", password: "password123", name: "Tester")
    call(:post, "/signup", { name: name, email: email, password: password })
    raise "signup failed: #{status} #{body}" unless status == 201
    @email = email
    self
  end

  def sign_in(email, password = "password123")
    @email = email
    call(:post, "/session", { email: email, password: password })
  end

  def get(path) = call(:get, path)
  def post(path, body = {}) = call(:post, path, body)
  def patch(path, body = {}) = call(:patch, path, body)
  def delete(path, body = nil) = call(:delete, path, body)
end

module ClientHelpers
  def client(**kw) = ApiClient.new(**kw)

  def make_admin!(email)
    User.find_by!(email: email).update_columns(admin: true)
  end
end
RSpec.configure { |c| c.include ClientHelpers }
