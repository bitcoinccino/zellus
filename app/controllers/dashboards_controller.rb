class DashboardsController < ApplicationController
  before_action :authenticate_user!

  def priolink
    @transactions = current_user.transactions.order(created_at: :desc).limit(5)
    @usdc_balance = current_user.transactions.where(status: :completed, transaction_type: :buy)
                                .sum(:crypto_amount)
  end

  def priosol
    @my_circles = current_user.sol_circles.includes(:sol_memberships).order(created_at: :desc).limit(5)
    @active_circles = current_user.sol_circles.where(status: :active)
  end

  def priobousad
  end

  def prionet
    @score = current_user.credit_score || 0
    @tier = current_user.credit_tier
    @next_tier_points = current_user.points_to_next_tier
    @completed_sols = current_user.sol_circles.where(status: :completed).count
    @active_sols = current_user.sol_circles.where(status: :active).count
  end

  def zellus
    @wallet = current_user.ensure_wallet!
    @ledger_entries = @wallet.wallet_ledger_entries.recent_first.limit(30)
  end
end
