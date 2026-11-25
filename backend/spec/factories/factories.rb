FactoryBot.define do
  factory :user do
    sequence(:email) { |n| "user#{n}@example.com" }
    name { "Test User" }
    password { "password123" }

    after(:create) do |user|
      account = user.create_account!(cash: 0)
      Accounts::Provision.call(account)
    end
  end

  factory :asset do
    sequence(:symbol) { |n| "T#{n}" }
    name { "Test Asset" }
    kind { "stock" }
    active { true }

    trait(:crypto) { kind { "crypto" } }
    trait(:etf) { kind { "etf" } }
  end

  factory :quote do
    asset
    price { BigDecimal("100") }
    previous_close { BigDecimal("99") }
    change_percent { BigDecimal("1.0101") }
    as_of { Clock.now }
    fetched_at { Clock.now }
  end
end
