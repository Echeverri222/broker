module MarketData
  # MKD-06: every provider HTTP call goes through here. Two protections, both shared across processes via Rails.cache:
  #   - a per-provider budget (calls per minute), so user traffic can never exceed the provider's limit;
  #   - a circuit breaker (opens after FAILURE_LIMIT consecutive failures, probes again after OPEN_FOR).
  # When either trips, ProviderError is raised and callers keep the stored quote (flagged stale).
  module Gateway
    FAILURE_LIMIT = 5
    OPEN_FOR = 30.seconds
    DEFAULT_BUDGETS = { "yahoo" => 120, "coingecko" => 30 }.freeze

    module_function

    def call(provider)
      raise ProviderError, "#{provider}: circuit open" if open?(provider)
      spend!(provider)
      begin
        result = yield
      rescue ProviderError
        record_failure(provider)
        raise
      end
      record_success(provider)
      result
    end

    def budget(provider)
      Integer(ENV.fetch("#{provider.upcase}_MAX_PER_MIN", DEFAULT_BUDGETS.fetch(provider, 60)))
    end

    # Calls made in the current minute (also exported as a metric, OBS-03).
    def calls_this_minute(provider) = Rails.cache.read(budget_key(provider)).to_i

    def open?(provider)
      opened = Rails.cache.read("gateway/#{provider}/opened_at")
      opened.present? && Clock.now.to_i - opened < OPEN_FOR
    end

    def state(provider)
      return "open" if open?(provider)
      Rails.cache.read("gateway/#{provider}/failures").to_i.positive? ? "half_open" : "closed"
    end

    def reset!(provider)
      %w[opened_at failures].each { |k| Rails.cache.delete("gateway/#{provider}/#{k}") }
      Rails.cache.delete(budget_key(provider))
    end

    def spend!(provider)
      n = Rails.cache.increment(budget_key(provider), 1, expires_in: 2.minutes, initial: 0)
      return if n.nil? || n <= budget(provider)
      raise ProviderError, "#{provider}: call budget of #{budget(provider)}/min exhausted"
    end

    def budget_key(provider) = "gateway/#{provider}/calls/#{Clock.now.to_i / 60}"

    def record_failure(provider)
      n = Rails.cache.increment("gateway/#{provider}/failures", 1, expires_in: 5.minutes, initial: 0).to_i
      return if n < FAILURE_LIMIT
      Rails.cache.write("gateway/#{provider}/opened_at", Clock.now.to_i, expires_in: 5.minutes)
      Rails.cache.write("gateway/#{provider}/failures", FAILURE_LIMIT - 1, expires_in: 5.minutes) # one failed probe re-opens it
      Rails.logger.error("market data circuit opened for #{provider}")
    end

    def record_success(provider)
      Rails.cache.delete("gateway/#{provider}/failures")
      Rails.cache.delete("gateway/#{provider}/opened_at")
    end
  end
end
