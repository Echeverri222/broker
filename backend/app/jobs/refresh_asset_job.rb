# MKD-01/02: the only place a single asset's quote is fetched on demand. Enqueued (deduplicated) by the request path.
class RefreshAssetJob < ApplicationJob
  queue_as :critical

  def perform(asset_id)
    asset = Asset.active.find_by(id: asset_id) or return
    Quotes::Refresh.refresh_asset(asset)
  end
end
