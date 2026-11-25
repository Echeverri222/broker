class SnapshotsJob < ApplicationJob
  queue_as :default

  # JOB-03: fans out one SnapshotAccountJob per eligible account instead of looping in one long job.
  def perform(kind = "hourly") = Snapshots::RecordAll.enqueue(kind: kind.to_sym)
end
