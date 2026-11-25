# ADM-04 / OBS-03: read-only view of the Solid Queue tables. Returns nil/empty when the queue database is not
# available (for example in tests), never raises.
module QueueStats
  module_function

  def available?
    defined?(SolidQueue::ReadyExecution) && SolidQueue::ReadyExecution.table_exists? ? true : false
  rescue StandardError
    false
  end

  # Seconds the oldest ready job has been waiting, or nil when nothing waits.
  def oldest_ready_age
    return nil unless available?
    oldest = SolidQueue::ReadyExecution.minimum(:created_at)
    oldest && (Time.current - oldest)
  rescue StandardError
    nil
  end

  def depth_by_queue
    return {} unless available?
    SolidQueue::ReadyExecution.group(:queue_name).count
  rescue StandardError
    {}
  end

  def failed(limit = 50)
    return [] unless defined?(SolidQueue::FailedExecution) && SolidQueue::FailedExecution.table_exists?
    SolidQueue::FailedExecution.includes(:job).order(created_at: :desc).limit(limit).map do |f|
      { id: f.id, job_class: f.job.class_name, queue: f.job.queue_name, error: f.error.to_s.first(300), failed_at: f.created_at.utc.iso8601 }
    end
  rescue StandardError
    []
  end
end
