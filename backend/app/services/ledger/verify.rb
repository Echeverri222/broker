# MON-05 / MON-06 checks, usable from specs and `rake ledger:verify`.
module Ledger
  class Verify
    def self.call = new.call

    def call
      problems = []
      Account.find_each do |a|
        deposits = a.deposits.sum(:amount)
        buys = a.orders.where(status: "filled", side: "buy").sum(:total)
        sells = a.orders.where(status: "filled", side: "sell").sum(:total)
        expected = deposits - buys + sells
        if a.cash != expected
          problems << { account_id: a.id, rule: "MON-05", detail: "cash #{a.cash} != #{expected}" }
        end
        check_positions(a, problems)
      end
      problems
    end

    private

    def check_positions(account, problems)
      adjustments = PositionAdjustment.where(account_id: account.id).group(:asset_id)
      by_asset = account.orders.where(status: "filled").group(:asset_id, :side).sum(:quantity)
      asset_ids = (by_asset.keys.map(&:first) + account.positions.pluck(:asset_id)).uniq
      asset_ids.each do |asset_id|
        bought = by_asset[[ asset_id, "buy" ]] || 0
        sold = by_asset[[ asset_id, "sell" ]] || 0
        expected = bought - sold + split_delta(account, asset_id)
        pos = account.positions.find_by(asset_id: asset_id)
        actual = pos&.quantity || 0
        problems << { account_id: account.id, rule: "MON-06", detail: "asset #{asset_id} qty #{actual} != #{expected}" } if actual != expected
      end
      adjustments
    end

    def split_delta(account, asset_id)
      PositionAdjustment.where(account_id: account.id, asset_id: asset_id).sum("quantity_after - quantity_before")
    end
  end
end
