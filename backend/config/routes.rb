Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  namespace :api do
    namespace :v1 do
      post "signup", to: "signups#create"
      resource :session, only: %i[create destroy]
      get "me", to: "me#show"
      get "market/status", to: "market#status"
      get "market/overview", to: "market#overview"
      resources :assets, only: %i[index show], param: :symbol, constraints: { symbol: %r{[^/]+} } do
        get :candles, on: :member
      end
      get "portfolio", to: "portfolio#show"
      get "portfolio/history", to: "portfolio#history"
      resources :orders, only: %i[index create destroy]
      resources :deposits, only: %i[index create]
      resources :watchlist, only: %i[index create destroy], param: :symbol, constraints: { symbol: %r{[^/]+} }
      post "account/reset", to: "accounts#reset"
    end
  end
end
