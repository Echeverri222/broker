class UiV3Data < ActiveRecord::Migration[8.1]
  def up
    add_column :assets, :sector, :string
    add_column :quotes, :stats, :jsonb # DAT-03: day range, open, volume, 52-week range cached with the quote
    Asset.reset_column_information
    Asset.find_each { |a| a.update_columns(sector: Asset.sector_for(a)) }
  end

  def down
    remove_column :quotes, :stats
    remove_column :assets, :sector
  end
end
