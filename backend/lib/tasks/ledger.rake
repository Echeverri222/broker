namespace :ledger do
  desc "Verify MON-05 (cash ledger) and MON-06 (positions) for every account"
  task verify: :environment do
    bad = Ledger::Verify.call
    if bad.empty?
      puts "ledger:verify OK (#{Account.count} accounts)"
    else
      bad.each { |b| warn "MISMATCH account=#{b[:account_id]} #{b[:rule]}: #{b[:detail]}" }
      exit 1
    end
  end
end
