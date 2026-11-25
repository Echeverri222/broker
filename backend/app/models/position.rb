class Position < ApplicationRecord
  belongs_to :account
  belongs_to :asset
end
