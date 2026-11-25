# Curated universe: US stocks/ETFs (incl. SPY) and major cryptocurrencies, all priced by real providers.
# provider_ref: Yahoo symbol for stocks/ETFs, CoinGecko coin id for crypto.
ASSETS = [
  [ "SPY", "SPDR S&P 500 ETF Trust", "etf", "SPY" ], [ "QQQ", "Invesco QQQ Trust", "etf", "QQQ" ],
  [ "VTI", "Vanguard Total Stock Market ETF", "etf", "VTI" ], [ "VOO", "Vanguard S&P 500 ETF", "etf", "VOO" ],
  [ "IWM", "iShares Russell 2000 ETF", "etf", "IWM" ], [ "DIA", "SPDR Dow Jones Industrial Average ETF", "etf", "DIA" ],
  [ "GLD", "SPDR Gold Shares", "etf", "GLD" ], [ "TLT", "iShares 20+ Year Treasury Bond ETF", "etf", "TLT" ],
  [ "AAPL", "Apple Inc.", "stock", "AAPL" ], [ "MSFT", "Microsoft Corporation", "stock", "MSFT" ],
  [ "GOOGL", "Alphabet Inc.", "stock", "GOOGL" ], [ "AMZN", "Amazon.com, Inc.", "stock", "AMZN" ],
  [ "NVDA", "NVIDIA Corporation", "stock", "NVDA" ], [ "META", "Meta Platforms, Inc.", "stock", "META" ],
  [ "TSLA", "Tesla, Inc.", "stock", "TSLA" ], [ "BRK.B", "Berkshire Hathaway Inc.", "stock", "BRK-B" ],
  [ "JPM", "JPMorgan Chase & Co.", "stock", "JPM" ], [ "V", "Visa Inc.", "stock", "V" ],
  [ "MA", "Mastercard Incorporated", "stock", "MA" ], [ "UNH", "UnitedHealth Group Incorporated", "stock", "UNH" ],
  [ "JNJ", "Johnson & Johnson", "stock", "JNJ" ], [ "WMT", "Walmart Inc.", "stock", "WMT" ],
  [ "PG", "The Procter & Gamble Company", "stock", "PG" ], [ "XOM", "Exxon Mobil Corporation", "stock", "XOM" ],
  [ "HD", "The Home Depot, Inc.", "stock", "HD" ], [ "KO", "The Coca-Cola Company", "stock", "KO" ],
  [ "PEP", "PepsiCo, Inc.", "stock", "PEP" ], [ "COST", "Costco Wholesale Corporation", "stock", "COST" ],
  [ "NFLX", "Netflix, Inc.", "stock", "NFLX" ], [ "DIS", "The Walt Disney Company", "stock", "DIS" ],
  [ "AMD", "Advanced Micro Devices, Inc.", "stock", "AMD" ], [ "INTC", "Intel Corporation", "stock", "INTC" ],
  [ "CRM", "Salesforce, Inc.", "stock", "CRM" ], [ "ORCL", "Oracle Corporation", "stock", "ORCL" ],
  [ "ADBE", "Adobe Inc.", "stock", "ADBE" ], [ "NKE", "NIKE, Inc.", "stock", "NKE" ],
  [ "MCD", "McDonald's Corporation", "stock", "MCD" ], [ "BA", "The Boeing Company", "stock", "BA" ],
  [ "PYPL", "PayPal Holdings, Inc.", "stock", "PYPL" ], [ "UBER", "Uber Technologies, Inc.", "stock", "UBER" ],
  [ "BTC", "Bitcoin", "crypto", "bitcoin" ], [ "ETH", "Ethereum", "crypto", "ethereum" ],
  [ "SOL", "Solana", "crypto", "solana" ], [ "BNB", "BNB", "crypto", "binancecoin" ], [ "XRP", "XRP", "crypto", "ripple" ],
  [ "ADA", "Cardano", "crypto", "cardano" ], [ "DOGE", "Dogecoin", "crypto", "dogecoin" ],
  [ "AVAX", "Avalanche", "crypto", "avalanche-2" ], [ "DOT", "Polkadot", "crypto", "polkadot" ],
  [ "LINK", "Chainlink", "crypto", "chainlink" ], [ "LTC", "Litecoin", "crypto", "litecoin" ],
  [ "BCH", "Bitcoin Cash", "crypto", "bitcoin-cash" ], [ "ATOM", "Cosmos", "crypto", "cosmos" ],
  [ "XLM", "Stellar", "crypto", "stellar" ]
].freeze

ASSETS.each do |symbol, name, kind, ref|
  asset = Asset.find_or_initialize_by(symbol: symbol)
  asset.update!(name: name, kind: kind, provider_ref: ref, active: true, sector: Asset.sector_for(Asset.new(symbol: symbol, kind: kind)))
end

Quotes::Refresh.call(force: true)
MarketData::Warm.call(throttle: 0.1) # DAT-06: sparklines, 52-week range and volume for the Markets list
missing = Asset.active.left_joins(:quote).where(quotes: { id: nil }).pluck(:symbol)
puts "Seeded #{Asset.count} assets, #{Quote.count} live quotes#{missing.any? ? " (no quote yet for: #{missing.join(', ')} — the refresh job will retry)" : ''}"
