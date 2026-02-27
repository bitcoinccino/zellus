Rails.application.routes.draw do
  if Rails.env.development? && defined?(LetterOpenerWeb::Engine)
    mount LetterOpenerWeb::Engine, at: "/letter_opener"
  end

  # --- Admin Merchant Center ---
  get 'admin/dashboard', to: 'admin#dashboard', as: :admin_dashboard
  post 'admin/transactions/:id/retry', to: 'admin#retry_transaction', as: :retry_admin_transaction
  post 'admin/transactions/:id/retry_payout', to: 'admin#retry_payout', as: :retry_admin_payout
  post 'admin/loans/:id/approve', to: 'admin#approve_loan', as: :approve_admin_loan

  # --- Identity & Security ---
  devise_for :users

  # --- The Core Exchange Logic ---
  resources :payment_methods, only: [:index, :create, :update, :destroy]
  resources :payment_requests, only: [:index, :new, :create, :show, :update, :destroy]
  get "r/:token", to: "payment_requests#public_show", as: :public_payment_request

  # --- Zèllus Transfers (Send Money) ---
  resources :transfers, only: [:new, :create, :show] do
    collection do
      post :set_pin
    end
    member do
      post :confirm
      get  :success
    end
  end
  get  "t/:token",       to: "transfers#claim",         as: :claim_transfer
  post "t/:token/claim",  to: "transfers#claim_confirm",  as: :confirm_claim_transfer

  # --- Priotelus Wallet ---
  resource :wallet, only: [:show] do
    post :deposit
    get  :deposit_success
    post :withdraw
  end

  # --- Pionye Loans (Repayment Integrated) ---
  resources :loans, only: [:new, :create] do
    member do
      post :repay # Generates repayment transaction/request
    end
  end

  # --- Standard Transactions (Buy/Sell) ---
  resources :transactions, only: [:index, :new, :create, :show] do
    member do
      post :pay 
      post :manual_confirm 
      post :submit_sell_tx_hash
    end
  end

  # --- Sol Community Banking ---
  resources :sol_circles, param: :token do
    member do
      get :success, to: "sol_memberships#success"
      get :join, to: "sol_memberships#join"
      post :confirm_join, to: "sol_memberships#confirm_join"
    end
  end

  # --- MonCash Webhooks ---
  get 'payment_success', to: 'transactions#success', as: :payment_success
  post 'moncash_webhook', to: 'moncash_webhooks#create'

  # --- Product Dashboards ---
  get "priolink",   to: "dashboards#priolink",   as: :priolink
  get "priosol",    to: "dashboards#priosol",    as: :priosol
  get "priobousad", to: "dashboards#priobousad", as: :priobousad
  get "prionet",    to: "dashboards#prionet",    as: :prionet
  get "zellus",     to: "dashboards#zellus",     as: :zellus

  # --- Homepage & Health ---
  root "transactions#new"
  get "up" => "rails/health#show", as: :rails_health_check
end
