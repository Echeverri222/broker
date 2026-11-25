module ApiHelpers
  JSON_HEADERS = { "CONTENT_TYPE" => "application/json", "ACCEPT" => "application/json" }.freeze

  # Every response is validated against openapi.yml (API-02), including error responses.
  def api(method, path, body = nil, headers = {})
    h = JSON_HEADERS.merge(headers)
    send(method, "/api/v1#{path}", params: body && body.to_json, headers: h)
    assert_response_schema_confirm(response.status) unless response.status == 429 && false
  end

  def json = JSON.parse(response.body, symbolize_names: true)

  def sign_up!(email: "u#{SecureRandom.hex(3)}@example.com", password: "password123")
    api(:post, "/signup", { name: "Tester", email: email, password: password })
    expect(response).to have_http_status(:created)
    email
  end

  def sign_out! = api(:delete, "/session")
end
RSpec.configure do |c|
  c.include Committee::Rails::Test::Methods, type: :request
  c.include ApiHelpers, type: :request
  c.add_setting :committee_options
  c.committee_options = { schema_path: Rails.root.join("openapi.yml").to_s, prefix: "/api/v1", parse_response_by_content_type: true, strict_reference_validation: true }
end

# committee-rails reads these helpers on the example group.
module CommitteeConfig
  def committee_options = RSpec.configuration.committee_options
  def request_object = request
  def response_data = [ response.status, response.headers, response.body ]
end
RSpec.configure { |c| c.include CommitteeConfig, type: :request }
