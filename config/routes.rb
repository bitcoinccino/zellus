Rails.application.routes.draw do
  if Rails.env.development? && defined?(LetterOpenerWeb::Engine)
    mount LetterOpenerWeb::Engine, at: "/letter_opener"
  end

  # --- Admin Merchant Center ---
  get 'admin/dashboard', to: 'admin#dashboard', as: :admin_dashboard
  post 'admin/transactions/:id/retry', to: 'admin#retry_transaction', as: :retry_admin_transaction
  post 'admin/transactions/:id/retry_payout', to: 'admin#retry_payout', as: :retry_admin_payout
  post 'admin/loans/:id/approve', to: 'admin#approve_loan', as: :approve_admin_loan
  get  'admin/invite_codes', to: 'admin#invite_codes', as: :admin_invite_codes
  post 'admin/invite_codes', to: 'admin#create_invite_code', as: :create_admin_invite_code
  post 'admin/invite_codes/:id/toggle', to: 'admin#toggle_invite_code', as: :toggle_admin_invite_code
  post 'admin/credit_wallet', to: 'admin#credit_wallet', as: :admin_credit_wallet
  post 'admin/bank_withdrawals/:id/process',  to: 'admin#process_bank_withdrawal',  as: :admin_process_bank_withdrawal
  post 'admin/bank_withdrawals/:id/complete', to: 'admin#complete_bank_withdrawal', as: :admin_complete_bank_withdrawal
  post 'admin/bank_withdrawals/:id/fail',     to: 'admin#fail_bank_withdrawal',     as: :admin_fail_bank_withdrawal

  # --- Identity & Security ---
  devise_for :users, controllers: { omniauth_callbacks: "users/omniauth_callbacks", registrations: "users/registrations" }
  resource :bonid_verification, only: [:show, :create], controller: "bon_id_verifications"
  get  "users/check_cashtag", to: "users#check_cashtag", as: :check_cashtag
  get  "users/lookup",        to: "users#lookup",         as: :user_lookup
  get  "setup_cashtag",       to: "users#setup_cashtag",  as: :setup_cashtag
  post "setup_cashtag",       to: "users#save_cashtag"
  delete "remove_avatar",     to: "users#remove_avatar",  as: :remove_avatar

  # --- The Core Exchange Logic ---
  resources :payment_methods, only: [:index, :create, :update, :destroy], param: :token
  resources :payment_requests, only: [:index, :new, :create, :show, :update, :destroy], param: :token
  get  "r/:token",         to: "payment_requests#public_show",     as: :public_payment_request
  post "r/:token/pay",     to: "payment_requests#pay",             as: :pay_payment_request
  post "r/:token/set_pin", to: "payment_requests#set_pin_for_pay", as: :set_pin_payment_request
  post "r/:token/dismiss", to: "payment_requests#dismiss",        as: :dismiss_payment_request

  # --- Notifikasyon ---
  resources :notifications, only: [:index] do
    member do
      match :mark_read, via: [:get, :post]
    end
    collection do
      match :mark_all_read, via: [:get, :post]
    end
  end

  # --- Zèllus pou Biznis ---
  resource :business, only: [:new, :create, :show, :edit, :update] do
    get :dashboard, on: :member
    get :payments, on: :member
    get :analytics, on: :member
    resources :products, only: [:new, :create, :edit, :update, :destroy]
  end
  get "b/:slug", to: "businesses#public_show", as: :public_business

  # --- Zèllus Transfers (Send Money) ---
  resources :transfers, only: [:new, :create, :show], param: :token do
    collection do
      post :set_pin
    end
    member do
      post :confirm
      get  :success
      get  :consent_status
      post :verify_consent
    end
  end
  get  "t/:token",       to: "transfers#claim",         as: :claim_transfer
  post "t/:token/claim",  to: "transfers#claim_confirm",  as: :confirm_claim_transfer

  # --- Zèllus Wallet ---
  resource :wallet, only: [:show] do
    get  :rates
    get  :balances
    get  :test_sound
    post :deposit
    get  :deposit_success
    post :withdraw
    post :withdraw_usdc
    post :withdraw_eth
    post :withdraw_wbtc
    post :withdraw_stock
    post :withdraw_bank
    post :convert
    post :claim_deposit
    post :verify_deposit_pin
    get  'entries/:token', action: :show_entry, as: :entry
  end

  # --- Pionye Loans (Repayment Integrated) ---
  resources :loans, only: [:new, :create] do
    member do
      post :repay         # Generates repayment transaction/request (MonCash/USDC)
      post :repay_wallet  # Instant wallet debit repayment
    end
  end

  # --- Standard Transactions (Buy/Sell) ---
  resources :transactions, only: [:index, :new, :create, :show], param: :ref do
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
      post :reorder, to: "sol_circles#reorder"
    end
  end

  # --- Webhooks ---
  get 'payment_success', to: 'transactions#success', as: :payment_success
  post 'moncash_webhook', to: 'moncash_webhooks#create'
  post 'bonid_consent_webhook', to: 'bonid_consent_webhooks#create'

  # --- Product Dashboards ---
  get "priosol",    to: "dashboards#priosol",    as: :priosol
  get "priobousad", to: "dashboards#priobousad", as: :priobousad
  get "prionet",    to: "dashboards#prionet",    as: :prionet
  get "zellus",     to: "dashboards#zellus",     as: :zellus

  # --- Public Product Info Pages ---
  get "pwodui/priosol",    to: "pages#priosol",    as: :priosol_info
  get "pwodui/priobousad", to: "pages#priobousad", as: :priobousad_info
  get "pwodui/prionet",    to: "pages#prionet",    as: :prionet_info
  get "pwodui/zellus",     to: "pages#zellus",     as: :zellus_info

  # --- Homepage & Health ---
  root "dashboards#zellus"
  get "up" => "rails/health#show", as: :rails_health_check
end
