class Asset < ApplicationRecord
  KINDS = %w[stock etf crypto].freeze
  # DAT-04: sector shown on the asset page and used by the Markets sector filter.
  SECTORS = {
    "Technology" => %w[AAPL MSFT GOOGL NVDA AMD INTC CRM ORCL ADBE],
    "Communication" => %w[META NFLX DIS],
    "Consumer" => %w[AMZN TSLA WMT PG HD KO PEP COST NKE MCD],
    "Financials" => %w[BRK.B JPM V MA PYPL],
    "Health care" => %w[UNH JNJ],
    "Energy" => %w[XOM],
    "Industrials" => %w[BA UBER],
    "Index funds" => %w[SPY QQQ VTI VOO IWM DIA GLD TLT]
  }.freeze
  SECTOR_BY_SYMBOL = SECTORS.flat_map { |sector, syms| syms.map { |s| [ s, sector ] } }.to_h.freeze

  def self.sector_for(asset)
    return "Crypto" if asset.kind == "crypto"
    SECTOR_BY_SYMBOL[asset.symbol]
  end

  has_one :quote, dependent: :destroy
  validates :symbol, :name, presence: true
  validates :kind, inclusion: { in: KINDS }

  scope :active, -> { where(active: true) }
  scope :search, ->(q) {
    q.present? ? where("symbol ILIKE :q OR name ILIKE :q", q: "%#{sanitize_sql_like(q.strip)}%") : all
  }

  # Typo-tolerant fallback for the search box ("aple" -> Apple, "bitcon" -> Bitcoin). Small universe, so done in memory.
  def self.fuzzy(q)
    needle = q.to_s.strip.downcase
    return none if needle.length < 3
    limit = needle.length >= 6 ? 2 : 1
    ids = active.select do |a|
      terms = [ a.symbol.downcase, *a.name.downcase.split(/[^a-z0-9]+/).reject(&:empty?) ]
      terms.any? { |t| edit_distance(needle, t[0, needle.length + 1]) <= limit || edit_distance(needle, t) <= limit }
    end.map(&:id)
    where(id: ids)
  end

  def self.edit_distance(a, b)
    prev = (0..b.length).to_a
    a.each_char.with_index(1) do |ca, i|
      cur = [ i ]
      b.each_char.with_index(1) { |cb, j| cur << [ prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca == cb ? 0 : 1) ].min }
      prev = cur
    end
    prev.last
  end

  def crypto? = kind == "crypto"
  def equity? = !crypto?
end
