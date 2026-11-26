Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check
  get "up/deep" => "health#deep"
  get "metrics" => "metrics#show"

  namespace :api do
    namespace :v1 do
      get "status", to: "status#show"
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
      patch "account/password", to: "accounts#password"
      patch "account/preferences", to: "accounts#preferences"
      get "account/export", to: "accounts#export"
      delete "account", to: "accounts#destroy"
      get "sessions", to: "active_sessions#index"
      delete "sessions", to: "active_sessions#destroy_others"
      delete "sessions/:id", to: "active_sessions#destroy"
      post "password_reset", to: "password_resets#create"
      patch "password_reset", to: "password_resets#update"
      post "email_verification", to: "email_verifications#create"
      patch "email_verification", to: "email_verifications#update"

      namespace :admin do
        post "reauth", to: "base#reauth"
        resources :users, only: %i[index show] do
          member do
            post :disable
            post :enable
            post :revoke_sessions
            post :password_reset
          end
        end
        resource :settings, only: %i[show update]
        get "queues", to: "jobs#index"
        post "jobs/:id/retry", to: "jobs#retry"
        delete "jobs/:id", to: "jobs#discard"
        get "audit_events", to: "audit_events#index"
        get "assets", to: "assets#index"
        patch "assets/:symbol", to: "assets#update"
      end
    end
  end
end
