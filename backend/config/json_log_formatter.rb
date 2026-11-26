require "json"

# OBS-02: one JSON object per line, so a log platform can index request_id, user_id, route, status and duration.
# Tags (request_id) become fields. Anything that looks like a secret or an email is scrubbed from the message.
class JsonLogFormatter < ::Logger::Formatter
  include ActiveSupport::TaggedLogging::Formatter

  SECRET = /(password|token|authorization|secret|cookie)=\S+/i
  EMAIL = /[\w.+-]+@[\w-]+(\.[\w-]+)+/

  def call(severity, time, progname, msg)
    line = { time: time.utc.iso8601(3), level: severity, message: scrub(format_message(msg)) }
    line[:progname] = progname if progname
    tags = current_tags
    line[:request_id] = tags.first if tags.any?
    "#{line.to_json}\n"
  end

  def scrub(text)
    text.to_s.gsub(SECRET) { "#{$1}=[FILTERED]" }.gsub(EMAIL, "[email]")
  end

  def format_message(msg)
    case msg
    when String then msg
    when Exception then "#{msg.class}: #{msg.message}"
    else msg.inspect
    end
  end
end
