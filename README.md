# Zellus

A Kreyòl-first consumer wallet for Haiti, built on **Base**.

> **Status: pre-launch — not production ready.** No public users, no live
> deployment, no real money. Everything below describes what is built and running
> in development. Known gaps remain in reconciliation, test coverage, and webhook
> hardening; this is not yet safe to run against real funds.

## Overview

Zellus bridges traditional Haitian financial rails and onchain dollars. Haitian
households save in US dollars but have no accessible dollar account — wealth sits
in paper cash, exposed to theft and to gourde depreciation. Zellus uses **USDC on
Base** to hand people a dollar they can actually hold, without asking them to
learn Web3.

### Core scope

1. **Buy** — purchase digital US dollars (*dola*) with Haitian gourdes (HTG)
2. **Convert** — swap balances between HTG and USDC
3. **Send** — peer-to-peer transfer by `$cashtag`
4. **Receive** — accept payments via identity-linked tags
5. **Cash out** — withdraw back to MonCash or a local bank account

Nothing else ships until those five are excellent. The repository contains
additional surfaces — merchant storefront and QR acceptance, agent cash-in, Sol
(ROSCA) circles, Bousad loans, UMA remittance — all behind off flags in
`config/initializers/feature_flags.rb` or incomplete. They are not part of v1.

## Identity: BonID

Formal identity infrastructure in Haiti is sparse, which is a bottleneck for
financial onboarding. Every Zellus account binds to **BonID**, a companion
identity product built alongside this one (also pre-launch). BonID is not a
government system and carries no official standing — it is our own verification
layer, built for the local environment.

## Architecture

Base is the settlement layer. Web3 complexity — seed phrases, gas, hex addresses
— is abstracted away from the interface entirely. Users see *dola* and a
`$cashtag`.

**Rails 8.0.1 / Ruby 3.3.0 · Postgres · Hotwire · Tailwind · Sidekiq + Solid Queue · Kamal**

### Implemented

- **USDC withdrawals** — routing to any Base address, with backend transaction
  signing (`secp256k1`), nonce locking, and refund recovery on failed broadcast.
- **Deposit detection** — polls Base event logs via `eth_getLogs` on a 5-minute
  cycle, with database-level deduplication against replays.
- **FX** — live HTG ↔ USDC conversion priced off real-time rate feeds, with a
  sanity band rejecting out-of-range values.
- **Ledger** — append-only wallet ledger entries, row-level locking on every
  mutation, DB-enforced idempotency via partial unique indexes on external
  payment IDs. Single-entry with stored balances (not double-entry).
- **MonCash** — payouts to Haiti's dominant mobile money rail.

### Single-chain by design

Base is the only chain. Scaffolding for ETH and wBTC exists in
`app/workers/eth_deposit_monitor_worker.rb` and `wbtc_deposit_monitor_worker.rb`
but is **disabled** — both return early in HTG+USD-only mode. Kept, not deleted,
pending a decision to remove.

### Known gaps

- The ledger core has no direct test coverage. Coverage is concentrated at the
  API boundary.
- No sanctions, PEP, or AML screening. Identity verification is BonID only.
- Deposit reconciliation and webhook hardening are incomplete. See the status
  note above — this is why it is not production ready.

## Running locally

Postgres must be running. Letter Opener is mounted at `/letter_opener` in
development for previewing outbound mail.

```bash
bin/setup   # bundle + db:prepare + log cleanup + starts server
```

Or manually:

```bash
bundle install
bin/rails db:prepare
bin/dev     # rails server + tailwind watch + sidekiq
```

## Author

**Davidson Louis** — Full-Stack Engineer & UI/UX Designer

- X: [handle]
- LinkedIn: [url]
