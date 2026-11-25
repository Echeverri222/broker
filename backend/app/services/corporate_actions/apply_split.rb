module CorporateActions
  # CA-02/03: store the split once; adjust every position open at the effective date.
  class ApplySplit
    # Returns :applied, :duplicate or :no_holders (the action is recorded in every case but :duplicate).
    def self.call(asset:, ratio:, effective_date:)
      ratio = BigDecimal(ratio.to_s)
      raise ArgumentError, "ratio must be positive" unless ratio.positive?
      cutoff = MarketCalendar::ZONE.local(effective_date.year, effective_date.month, effective_date.day)

      CorporateAction.transaction do
        action = CorporateAction.create!(asset: asset, kind: "split", ratio: ratio, effective_date: effective_date)
        positions = Position.where(asset: asset).where("created_at < ?", cutoff).lock.to_a
        positions.each do |pos|
          before_q, before_c = pos.quantity, pos.average_cost
          after_q = (before_q * ratio).round(8, :down)
          after_c = (before_c / ratio).round(8, :half_up)
          PositionAdjustment.create!(account_id: pos.account_id, asset: asset, corporate_action: action,
                                     quantity_before: before_q, quantity_after: after_q,
                                     average_cost_before: before_c, average_cost_after: after_c)
          pos.update!(quantity: after_q, average_cost: after_c)
        end
        positions.empty? ? :no_holders : :applied
      end
    rescue ActiveRecord::RecordNotUnique
      :duplicate
    end
  end

  # CA-01: for every held asset plus SPY, import splits from the last week (idempotent via CA-02).
  class Sync
    LOOKBACK = 7.days

    def self.call(now: Clock.now)
      ids = Position.distinct.pluck(:asset_id)
      assets = Asset.active.where(id: ids).or(Asset.active.where(symbol: "SPY")).where.not(kind: "crypto")
      assets.each_with_object({}) do |asset, out|
        out[asset.symbol] = MarketData.splits(asset, from: now - LOOKBACK).map do |date, ratio|
          ApplySplit.call(asset: asset, ratio: ratio, effective_date: date)
        end
      rescue MarketData::ProviderError => e
        Rails.logger.warn("splits sync failed for #{asset.symbol}: #{e.message}")
      end
    end
  end
end
