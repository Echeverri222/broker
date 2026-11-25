module Deposits
  # Virtual deposit (DEP-01..03): adds cash and a ledger row so returns exclude it.
  class Create
    MIN = BigDecimal("1")
    MAX = BigDecimal("10000000")
    Result = Struct.new(:deposit, :created, keyword_init: true)

    # `kind: "initial"` is used internally for signup/reset (no key needed).
    def self.call(account:, amount:, kind: "deposit", idempotency_key: nil)
      key = idempotency_key.to_s
      if kind == "deposit" && !key.match?(/\A[\x20-\x7E]{1,255}\z/)
        raise ApiError.new(:idempotency_key_required, "An Idempotency-Key header (1-255 printable characters) is required.")
      end
      key = nil if key.empty?
      amt = DecimalInput.parse(amount, "amount", max_places: 2)
      raise ApiError.new(:validation_failed, "amount is required") if amt.nil?
      raise ApiError.new(:below_minimum, "Minimum deposit is $1.00") if amt < MIN
      raise ApiError.new(:validation_failed, "Maximum deposit is $#{MAX.to_i}") if amt > MAX
      hash = Digest::SHA256.hexdigest([ "deposit", amt.to_s("F") ].to_json)

      Deposit.transaction do
        account.lock!
        if key && (existing = account.deposits.find_by(idempotency_key: key))
          if existing.request_hash.present? && existing.request_hash != hash
            raise ApiError.new(:idempotency_conflict, "This Idempotency-Key was already used with a different deposit.")
          end
          return Result.new(deposit: existing, created: false)
        end
        dep = account.deposits.create!(amount: amt, kind: kind, idempotency_key: key, request_hash: hash)
        account.update!(cash: account.cash + amt)
        Snapshots::Record.call(account)
        Result.new(deposit: dep, created: true)
      end
    rescue ActiveRecord::RecordNotUnique
      Result.new(deposit: account.deposits.find_by!(idempotency_key: key), created: false)
    end
  end
end
