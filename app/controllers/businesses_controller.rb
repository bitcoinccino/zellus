class BusinessesController < ApplicationController
  before_action :authenticate_user!, except: [:public_show]
  before_action :set_business, only: [:show, :edit, :update, :dashboard, :payments, :analytics]

  # ── GET /business/new ──
  def new
    if current_user.business.present?
      redirect_to business_path, notice: "Ou deja gen yon biznis."
      return
    end
    @business = current_user.build_business(fee_rate: 0.015)
  end

  # ── POST /business ──
  def create
    if current_user.business.present?
      redirect_to business_path, alert: "Ou deja gen yon biznis."
      return
    end

    @business = current_user.build_business(business_params)
    @business.slug ||= @business.name&.parameterize

    if @business.save
      redirect_to business_path, notice: "Biznis ou kreye avèk siksè! 🎉"
    else
      render :new, status: :unprocessable_entity
    end
  end

  # ── GET /business ──
  def show
    redirect_to new_business_path and return unless @business
    @products = @business.products.ordered
  end

  # ── GET /business/edit ──
  def edit
    redirect_to new_business_path and return unless @business
  end

  # ── PATCH /business ──
  def update
    redirect_to new_business_path and return unless @business

    if @business.update(business_params)
      redirect_to business_path, notice: "Biznis ou mete ajou avèk siksè!"
    else
      render :edit, status: :unprocessable_entity
    end
  end

  # ── GET /business/dashboard ──
  def dashboard
    redirect_to new_business_path and return unless @business

    @recent_transfers = @business.transfers
                                 .order(created_at: :desc)
                                 .limit(20)
    @top_products = @business.products
                             .where("sold_count > 0")
                             .order(total_revenue: :desc)
                             .limit(5)

    # Monthly stats
    @this_month_received = @business.transfers
                                     .where("created_at >= ?", Time.current.beginning_of_month)
                                     .sum(:amount)
    @this_month_count = @business.transfers
                                  .where("created_at >= ?", Time.current.beginning_of_month)
                                  .count
  end

  # ── GET /business/payments ──
  def payments
    redirect_to new_business_path and return unless @business

    @transfers = @business.transfers
                          .order(created_at: :desc)
                          .page(params[:page])
                          .per(25)
  rescue NoMethodError
    # If kaminari/pagy not available, load all
    @transfers = @business.transfers.order(created_at: :desc).limit(50)
  end

  # ── GET /business/analytics ──
  def analytics
    redirect_to new_business_path and return unless @business

    @top_products = @business.products
                             .where("sold_count > 0")
                             .order(total_revenue: :desc)
                             .limit(10)

    # Last 6 months volume
    @monthly_data = (0..5).map do |i|
      month_start = i.months.ago.beginning_of_month
      month_end = i.months.ago.end_of_month
      volume = @business.transfers
                        .where(created_at: month_start..month_end)
                        .sum(:amount)
      { month: month_start.strftime("%b %Y"), volume: volume }
    end.reverse
  end

  # ── GET /b/:slug — Public storefront (no auth) ──
  def public_show
    @business = Business.find_by!(slug: params[:slug])
    @products = @business.products.active.ordered
    @owner = @business.user

    render layout: "application"
  rescue ActiveRecord::RecordNotFound
    redirect_to root_path, alert: "Biznis sa a pa egziste."
  end

  private

  def set_business
    @business = current_user.business
  end

  def business_params
    params.require(:business).permit(
      :name, :slug, :category, :subcategory, :description,
      :commune, :department, :address, :phone,
      :fee_rate, :auto_settle, :settlement_method,
      :tax_id, :logo, accepted_currencies: []
    )
  end
end
