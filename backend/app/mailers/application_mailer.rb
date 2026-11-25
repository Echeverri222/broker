class ApplicationMailer < ActionMailer::Base
  default from: -> { ENV.fetch("MAIL_FROM", "Paper Broker <no-reply@localhost>") }
  layout false

  private

  # Links point at the SPA (one origin with the API, OPS-02).
  def app_url(path) = "#{ENV.fetch('APP_URL', 'http://localhost:5173').chomp('/')}#{path}"
end
