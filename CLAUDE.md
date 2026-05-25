# Zellus

Haitian banking / fintech platform. Single Rails monolith hosting four product
surfaces (Zellus / Priobousad / Priosol / Prionet) plus an OAuth provider and
admin panel.

## Stack

- **Rails** 8.0.1 on **Ruby 3.3.0** (`.ruby-version`)
- **Postgres** (dev DB: `bon_bank_development`)
- **Asset pipeline:** Propshaft + Importmap (no esbuild/jsbundling)
- **Hotwire:** Turbo + Stimulus
- **CSS:** Tailwind via `tailwindcss-rails`
- **Background jobs:** Sidekiq + Redis **and** Solid Queue side-by-side — check
  the job class to know which adapter it targets before changing scheduling
- **Cache / Cable:** Solid Cache + Solid Cable
- **Deploy:** Kamal + Thruster

## Domain at a glance

Schema and model names map to these themes:

| Theme | Tables / models |
|---|---|
| Identity & auth | `users` (Devise + OmniAuth), `oauth_clients`, `oauth_tokens`, `bonid_consent_requests` |
| Wallets & ledger | `wallets`, `wallet_ledger_entries`, `treasury_sweeps` |
| Money movement | `transactions`, `transfers`, `payment_methods`, `payment_requests`, `bank_withdrawals` |
| Checkout / commerce | `checkout_sessions`, `business_payment_links`, `business_line_items`, `products`, `businesses` |
| Agent network | `agent_transactions` (cash-in/out via field agents) |
| **Sol (ROSCA)** | `sol_circles`, `sol_rounds`, `sol_memberships`, `sol_contributions`, `sol_escrow_accounts`, `sol_ledger_entries` — Haitian rotating savings circles |
| **Bousad (loans)** | `loans_controller.rb`, `loan_mailer`, admin "Bousad" endpoints |
| External rails | `lightspark_webhooks` (Bitcoin Lightning), `moncash_webhooks` (Haiti's MonCash), `blockchain_deposit_monitors`, `eth` gem |
| Ops | `webhook_deliveries`, `notifications`, `api_idempotency_keys`, `invite_codes`, `exchange_rates` |

**Encryption:** `lockbox` gem for attribute-level encryption — check
`config/initializers/` for box config before adding new encrypted fields.

**OAuth provider:** Zellus issues its own OAuth tokens
(`app/controllers/oauth_controller.rb`). Flash messages in Kreyòl
(`"Aplikasyon pa rekonèt."`) — primary UI language is **Haitian Kreyòl**.

## Four product surfaces

`root → dashboards#zellus`. The other three render at sibling actions on the
same controller:

- `dashboards/zellus.html.erb` — main consumer wallet
- `dashboards/priobousad.html.erb` — lending product
- `dashboards/priosol.html.erb` — Sol circles product
- `dashboards/prionet.html.erb` — (network / agent surface)

Treat product-specific changes as scoped to one of these dashboards unless the
ask says otherwise.

## Running locally

```bash
bin/setup                    # bundle + db:prepare + log cleanup + starts server
# or manually:
bundle install
bin/rails db:prepare
bin/dev                      # rails server + tailwind watch + sidekiq, one tab
```

`bin/dev` is a plain bash script (no foreman dependency) that runs the three
processes in parallel and forwards Ctrl-C to all of them. Output is
interleaved; if you want foreman-style prefixes, run `foreman start -f
Procfile.dev` or `overmind start -f Procfile.dev` instead.

Postgres must be running locally. Letter Opener is mounted at
`/letter_opener` in development for previewing outbound mail.

## Admin

`/admin/*` is a manually-built admin (not ActiveAdmin) under
`app/controllers/admin/`. Covers credit, treasury reveal, system health,
transaction/payout retries, loan approval, agent applicants, business
applicants, Bousad loan review, invite codes, activity feed.

## Conventions worth knowing

- **Feature flags:** `config/initializers/feature_flags.rb` — gate new code
  behind a flag instead of hard-on by default
- **Brand:** `config/initializers/app_brand.rb` — central place for brand
  tokens; prefer editing here over scattering hex codes
- **Idempotency:** API endpoints use `ApiIdempotencyKey` — check before
  duplicating webhook/payment handlers
- **`require_cashtag!`** before_action exists across some controllers
  (see `OauthController`); be aware before adding new public endpoints

## Sibling repos

- `../bonid` — identity issuer; Zellus consumes BonID via OAuth +
  `bonid_consent_requests` + the two `bonid_*_webhooks_controllers`
- `../hosalivio-web` — separate hospice care platform
