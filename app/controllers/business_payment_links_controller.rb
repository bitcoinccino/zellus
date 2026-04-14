class BusinessPaymentLinksController < ApplicationController
  include RateLimitable

  before_action :authenticate_user!, except: [:public_show]
  before_action :set_business, except: [:public_show]
  before_action :rate_limit!, only: [:public_show]

  # ── GET /business/payment_links ──
  def index
    @links = @business.payment_links.recent_first
  end

  # ── GET /business/payment_links/:id ──
  def show
    @link = find_link!
  end

  # ── GET /business/payment_links/new ──
  def new
    @link = @business.payment_links.build(asset: "htg")
  end

  # ── POST /business/payment_links ──
  def create
    @link = @business.payment_links.build(link_params)

    # Parse items JSON from the form hidden field
    if params[:business_payment_link][:items_json].present?
      parsed = JSON.parse(params[:business_payment_link][:items_json]) rescue []
      @link.items = parsed if parsed.is_a?(Array) && parsed.any?
    end

    if @link.save
      redirect_to business_payment_link_path(@link), notice: "Lyen pèman kreye! Kopye lyen an epi pataje li."
    else
      render :new, status: :unprocessable_entity
    end
  end

  # ── GET /business/payment_links/:id/edit ──
  def edit
    @link = find_link!
  end

  # ── PATCH /business/payment_links/:id ──
  def update
    @link = find_link!

    # Parse items JSON from the form hidden field
    if params[:business_payment_link][:items_json].present?
      parsed = JSON.parse(params[:business_payment_link][:items_json]) rescue []
      @link.items = parsed if parsed.is_a?(Array) && parsed.any?
    elsif params[:business_payment_link][:items_json] == "[]"
      @link.items = []
    end

    if @link.update(link_params)
      redirect_to business_payment_link_path(@link), notice: "Lyen pèman mete ajou."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  # ── PATCH /business/payment_links/:id/toggle ──
  def toggle
    link = find_link!
    new_status = link.disabled? ? :active : :disabled
    link.update!(status: new_status)
    notice = link.disabled? ? "Lyen pèman dezaktive." : "Lyen pèman reaktive!"
    redirect_to business_payment_links_path, notice: notice
  end

  # ── DELETE /business/payment_links/:id ──
  def destroy
    link = find_link!
    link.destroy!
    redirect_to business_payment_links_path, notice: "Lyen pèman efase."
  end

  # ── GET /p/:token — Public payment link (no auth, rate limited) ──
  def public_show
    @link = BusinessPaymentLink.find_by!(token: params[:token])

    if @link.disabled?
      redirect_to root_path, alert: "Lyen pèman sa a dezaktive."
      return
    end

    if @link.paid?
      redirect_to root_path, alert: "Lyen pèman sa a deja itilize. Li pa valid ankò."
      return
    end

    @link.mark_expired_if_needed!
    if @link.expired?
      redirect_to root_path, alert: "Lyen pèman sa a ekspire."
      return
    end

    # Redirect to the business pay page with pre-filled params
    params_hash = { asset: @link.asset }
    params_hash[:amount] = @link.amount if @link.amount.present?
    params_hash[:note] = @link.note if @link.note.present?
    params_hash[:cart_items] = @link.items.to_json if @link.itemized?
    # Always pass tips setting from link — overrides business default
    params_hash[:tips] = @link.allow_tips? ? "1" : "0"

    redirect_to pay_business_path(@link.business.slug, **params_hash), allow_other_host: false
  rescue ActiveRecord::RecordNotFound
    redirect_to root_path, alert: "Lyen pèman sa a pa egziste."
  end

  private

  def set_business
    @business = current_user.business
    redirect_to new_business_path, alert: "Kreye yon biznis anvan." unless @business
  end

  def find_link!
    @business.payment_links.find_by!(token: params[:id])
  end

  def link_params
    params.require(:business_payment_link).permit(:amount, :asset, :note, :single_use, :expires_at, :allow_tips)
  end
end
