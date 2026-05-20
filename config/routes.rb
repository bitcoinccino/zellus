Rails.application.routes.draw do
  if Rails.env.development? && defined?(LetterOpenerWeb::Engine)
    mount LetterOpenerWeb::Engine, at: "/letter_opener"
  end

  # --- Admin Panel ---
  namespace :admin do
    get "/", to: "dashboard#index", as: :root

    # Dashboard
    get  "dashboard", to: "dashboard#index"
    get  "credit",    to: "dashboard#credit"
    post "credit_wallet", to: "dashboard#credit_wallet"
    post "credit_external", to: "dashboard#credit_external"
    post "reveal_treasury", to: "dashboard#reveal_treasury"
    get  "system_health", to: "dashboard#system_health"
    post "transactions/:id/retry",       to: "dashboard#retry_transaction",       as: :retry_transaction
    post "transactions/:id/retry_payout", to: "dashboard#retry_payout",           as: :retry_payout
    post "loans/:id/approve",            to: "dashboard#approve_loan",            as: :approve_loan
    post "bank_withdrawals/:id/process",  to: "dashboard#process_bank_withdrawal",  as: :process_bank_withdrawal
    post "bank_withdrawals/:id/complete", to: "dashboard#complete_bank_withdrawal", as: :complete_bank_withdrawal
    post "bank_withdrawals/:id/fail",     to: "dashboard#fail_bank_withdrawal",     as: :fail_bank_withdrawal

    # Invite Codes
    resources :invite_codes, only: [:index, :create, :destroy] do
      post :toggle, on: :member
      post :expire, on: :member
    end

    # Agents
    get  "agents/applicants",     to: "agents#applicants",  as: :agents_applicants
    get  "agents/applicants/:id", to: "agents#show",        as: :agents_show
    post "agents/:id/approve",    to: "agents#approve",     as: :approve_agent
    post "agents/:id/reject",     to: "agents#reject",      as: :reject_agent
    post "agents/:id/suspend",    to: "agents#suspend",     as: :suspend_agent
    post "agents/:id/reactivate", to: "agents#reactivate",  as: :reactivate_agent
    get  "agents/analytics",      to: "agents#analytics",   as: :agents_analytics
    get  "agents/activity",       to: "agents#activity",    as: :agents_activity

    # Activity (unified feed)
    get "activity",                          to: "dashboard#activity",      as: :activity
    get "activity/:activity_type/:id",       to: "dashboard#activity_show", as: :activity_detail

    # Dashboard chart data (JSON)
    get "dashboard/chart_data", to: "dashboard#chart_data", as: :dashboard_chart_data

    # Users
    get "users/analytics", to: "users#analytics", as: :users_analytics

    # Businesses
    get  "businesses/applicants",        to: "businesses#applicants",   as: :businesses_applicants
    get  "businesses/analytics",         to: "businesses#analytics",    as: :businesses_analytics
    get  "businesses/activity",          to: "businesses#activity",     as: :businesses_activity
    post "businesses/:id/toggle_agent",  to: "businesses#toggle_agent", as: :toggle_agent

    # Bousad (Loans)
    get  "bousad/applicants",   to: "bousad#applicants",  as: :bousad_applicants
    post "bousad/:id/approve",  to: "bousad#approve",     as: :approve_bousad
    post "bousad/:id/reject",   to: "bousad#reject",      as: :reject_bousad
    get  "bousad/analytics",    to: "bousad#analytics",   as: :bousad_analytics
    get  "bousad/activity",     to: "bousad#activity",    as: :bousad_activity

    # Developers (API clients + webhooks)
    resources :developers, only: [:index, :show, :create, :update, :destroy] do
      member do
        post :regenerate_secret
        post :test_webhook
      end
    end
  end

  # --- Identity & Security ---
  devise_for :users, controllers: {
    omniauth_callbacks: "users/omniauth_callbacks",
    registrations:      "users/registrations",
    sessions:           "users/sessions"
  }

  # OTP sign-in / sign-up (replaces password login). Old /users/sign_in still
  # exists via Devise but redirects to /login below.
  get  "login",        to: "otp_auth#new",     as: :login
  post "login",        to: "otp_auth#create"
  get  "login/verify", to: "otp_auth#verify",  as: :login_verify
  post "login/verify", to: "otp_auth#confirm"

  devise_scope :user do
    get "/users/sign_in", to: redirect("/login")
    get "/users/sign_up", to: redirect("/login")
  end

  # New-user onboarding gate (set in OtpAuthController#confirm)
  get  "onboarding/profile",        to: "onboarding#profile",                as: :onboarding_profile
  post "onboarding/profile",        to: "onboarding#update_profile"
  get  "onboarding/pin",            to: "onboarding#pin",                    as: :onboarding_pin
  post "onboarding/pin",            to: "onboarding#update_pin"
  get  "onboarding/payment_method", to: "onboarding#payment_method",         as: :onboarding_payment_method
  post "onboarding/payment_method", to: "onboarding#update_payment_method"

  resource :bonid_verification, only: [:show, :create], controller: "bon_id_verifications"
  get  "users/check_cashtag", to: "users#check_cashtag", as: :check_cashtag
  get  "users/lookup",        to: "users#lookup",         as: :user_lookup
  get  "setup_cashtag",       to: "users#setup_cashtag",  as: :setup_cashtag
  post "setup_cashtag",       to: "users#save_cashtag"
  delete "remove_avatar",     to: "users#remove_avatar",  as: :remove_avatar

  # --- The Core Exchange Logic ---
  resources :payment_methods, only: [:index, :create, :update, :destroy], param: :token do
    member do
      patch :set_default
    end
  end
  resources :payment_requests, only: [:index, :new, :create, :show, :update, :destroy], param: :token
  # --- Partner Checkout ---
  get  "pay/:token",          to: "checkouts#show",    as: :checkout_pay
  post "pay/:token/confirm",  to: "checkouts#confirm", as: :checkout_confirm
  post "pay/:token/cancel",   to: "checkouts#cancel",  as: :checkout_cancel

  get  "r/:token",         to: "payment_requests#public_show",     as: :public_payment_request
  post "r/:token/pay",     to: "payment_requests#pay",             as: :pay_payment_request
  post "r/:token/set_pin", to: "payment_requests#set_pin_for_pay", as: :set_pin_payment_request
  post "r/:token/dismiss", to: "payment_requests#dismiss",        as: :dismiss_payment_request
  post "r/:token/decline", to: "payment_requests#decline",      as: :decline_payment_request

  # --- Notifikasyon ---
  resources :notifications, only: [:index, :show] do
    member do
      match :mark_read, via: [:get, :post]
      post :send_thanks
    end
    collection do
      match :mark_all_read, via: [:get, :post]
      get :poll
    end
  end

  # --- Zèllus pou Biznis ---
  resource :business, only: [:new, :create, :show, :edit, :update] do
    get :check_slug, on: :collection
    get :dashboard, on: :member
    get :payments, on: :member
    get :analytics, on: :member
    get :button, on: :member
    post :apply_agent, on: :member
    get  :agent_kit, on: :member
    post :upload_signage, on: :member
    resources :products, only: [:index, :new, :create, :edit, :update, :destroy]
    resources :agent_transactions, only: [:create, :index]
    resources :payment_links, only: [:index, :show, :new, :create, :edit, :update, :destroy], controller: "business_payment_links" do
      patch :toggle, on: :member
    end
  end
  get "b/:slug",        to: "businesses#public_show",  as: :public_business
  get  "b/:slug/pay",    to: "businesses#pay_page",     as: :pay_business
  post "b/:slug/pay",    to: "businesses#quick_pay"
  get "b/:slug/products", to: "businesses#product_index", as: :public_products
  get "b/:slug/p/:token",  to: "businesses#product_show",  as: :public_product
  get "p/:token",    to: "business_payment_links#public_show", as: :public_payment_link
  get "button/:slug.js", to: "businesses#button_js", as: :business_button_js

  # --- Zèllus Transfers (Send Money) ---
  resources :transfers, only: [:new, :create, :show], param: :token do
    collection do
      post :set_pin
    end
    member do
      post :confirm
      get  :success
      get  :consent_status
      post :recheck_consent
    end
  end
  get  "t/:token",       to: "transfers#claim",         as: :claim_transfer
  post "t/:token/claim",  to: "transfers#claim_confirm",  as: :confirm_claim_transfer

  # --- Zèllus Wallet ---
  resource :wallet, only: [:show] do
    get  :rates
    get  :balances
    get  :limits
    get  :test_sound
    post :deposit
    get  :deposit_success
    post :withdraw
    post :withdraw_usd
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

  # --- BonID OAuth Provider ---
  get  "oauth/authorize", to: "oauth#authorize", as: :oauth_authorize
  post "oauth/decision",  to: "oauth#decision",  as: :oauth_decision
  post "oauth/token",     to: "oauth#token",     as: :oauth_token

  # --- BonID Identity API + Zellus Financial API ---
  namespace :api do
    namespace :v1 do
      get "identity", to: "identity#show"

      # Financial API (v1)
      get  "wallet",           to: "wallet#show"
      get  "transactions",     to: "transactions#index"
      post "transfers",        to: "transfers#create"
      get  "transfers/:token", to: "transfers#show", as: :transfer
      post "withdrawals",      to: "withdrawals#create"

      # Checkout Sessions
      post "checkouts",              to: "checkouts#create"
      get  "checkouts/:token",       to: "checkouts#show",   as: :checkout
      post "checkouts/:token/refund", to: "checkouts#refund", as: :checkout_refund
    end
  end

  # --- Webhooks ---
  get 'payment_success', to: 'transactions#success', as: :payment_success
  post 'moncash_webhook', to: 'moncash_webhooks#create'
  post 'bonid_consent_webhook', to: 'bonid_consent_webhooks#create'
  post 'bonid_revocation_webhook', to: 'bonid_revocation_webhooks#create'
  post 'circle_webhook', to: 'api/circle_webhooks#create'
  post 'lightspark_webhook', to: 'lightspark_webhooks#create'

  # --- UMA Protocol (Universal Money Address) ---
  get  '.well-known/lnurlp/:username',        to: 'uma#lnurlp'
  post '.well-known/lnurlp/:username/payreq',  to: 'uma#payreq'

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
  get "pwodui/ajan",       to: "pages#ajan",       as: :ajan_info
  get "resevwa",            to: "pages#resevwa",    as: :resevwa
  get "apwopo",             to: "pages#apwopo",     as: :apwopo
  get "faq",                to: "pages#faq",        as: :faq
  get "annye",              to: "pages#annye",      as: :annye
  get "annyè",              to: "pages#annye"

  # --- Homepage & Health ---
  root "dashboards#zellus"
  get "up" => "rails/health#show", as: :rails_health_check
end
