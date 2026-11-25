class PositionAdjustment < ApplicationRecord
  belongs_to :account
  belongs_to :asset
  belongs_to :corporate_action
end
