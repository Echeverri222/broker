class ApplicationJob < ActiveJob::Base
  # JOB-04: jobs are idempotent, so transient failures retry with backoff instead of being lost.
  retry_on ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout, wait: :polynomially_longer, attempts: 5
  retry_on MarketData::ProviderError, wait: 10.seconds, attempts: 3
  discard_on ActiveJob::DeserializationError
end
