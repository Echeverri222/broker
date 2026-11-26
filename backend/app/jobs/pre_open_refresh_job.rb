# MKD-05: a minute before the open, refresh every asset that has a waiting order, so the burst at 9:30 fills at
# fresh prices with one provider call per asset (never one per order).
class PreOpenRefreshJob < ApplicationJob
  queue_as :critical

  def perform
    ids = Order.pending.distinct.pluck(:asset_id)
    Asset.active.where(id: ids).find_each { |asset| Quotes::Refresh.refresh_asset(asset) }
    ids.size
  end
end
