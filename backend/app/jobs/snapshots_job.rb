class SnapshotsJob < ApplicationJob
  def perform(kind = "hourly") = Snapshots::RecordAll.call(kind: kind.to_sym)
end
