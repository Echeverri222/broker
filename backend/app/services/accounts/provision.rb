module Accounts
  # Gives an (empty, cash 0) account its STARTING_CASH as an `initial` deposit plus a first snapshot.
  # Must be called inside the caller's transaction (signup, reset) so a failure leaves nothing behind.
  class Provision
    def self.call(account, now: Clock.now)
      amount = Account.starting_cash
      account.deposits.create!(amount: amount, kind: "initial", created_at: now,
                               request_hash: Digest::SHA256.hexdigest([ "deposit", amount.to_s("F") ].to_json))
      account.update!(cash: amount)
      Snapshots::Record.call(account, at: now)
    end
  end
end
