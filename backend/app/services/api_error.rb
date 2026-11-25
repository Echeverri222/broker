class ApiError < StandardError
  STATUS = {
    unauthenticated: 401, not_found: 404, validation_failed: 422, insufficient_funds: 422,
    insufficient_quantity: 422, market_closed: 422, price_unavailable: 503, below_minimum: 422,
    idempotency_conflict: 422, idempotency_key_required: 422, unsupported_media_type: 415,
    rate_limited: 429, internal: 500, order_not_pending: 409, too_many_pending_orders: 422
  }.freeze

  attr_reader :code, :details

  def initialize(code, message, details = {})
    super(message)
    @code = code
    @details = details
  end

  def status = STATUS.fetch(code, 422)
end
