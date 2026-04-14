class BusinessesController < ApplicationController
  include RateLimitable

  before_action :authenticate_user!, except: [:public_show, :pay_page, :product_index, :product_show, :button_js]
  before_action :set_business, only: [:show, :edit, :update, :dashboard, :payments, :analytics, :apply_agent, :agent_kit, :upload_signage, :button]
  before_action :rate_limit!, only: [:pay_page, :quick_pay]

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

  # ── POST /business/apply_agent ──
  def apply_agent
    redirect_to new_business_path and return unless @business

    if @business.agent_application_pending?
      redirect_to wallet_path, alert: "Aplikasyon ou deja soumèt. Tann apwobasyon admin."
      return
    end

    unless @business.agent_eligible?
      errors = @business.agent_eligibility_errors.join(", ")
      redirect_to wallet_path, alert: "Ou pa kalifye pou vin ajan: #{errors}"
      return
    end

    begin
      @business.apply_for_agent!
      redirect_to wallet_path, notice: "Aplikasyon ajan ou soumèt! Nou pral revize li byento."
    rescue => e
      redirect_to wallet_path, alert: "Erè: #{e.message}"
    end
  end

  # ── GET /business/agent_kit (PDF) ──
  def agent_kit
    unless @business&.agent?
      redirect_to business_path, alert: "Ou dwe yon ajan apwouve pou telechaje kit la."
      return
    end

    pdf_data = AgentKitService.generate_pdf(@business)
    send_data pdf_data,
      filename: "zellus-ajan-kit-#{@business.slug}.pdf",
      type: "application/pdf",
      disposition: "inline"
  end

  # ── POST /business/upload_signage ──
  def upload_signage
    unless @business&.agent?
      redirect_to business_path, alert: "Ou dwe yon ajan apwouve."
      return
    end

    if params[:signage_photo].blank?
      redirect_to wallet_path, alert: "Chwazi yon foto afich ou."
      return
    end

    @business.signage_photo.attach(params[:signage_photo])
    @business.update!(signage_verified: false)
    redirect_to wallet_path, notice: "Foto afich ou soumèt pou verifikasyon. Ou pral resevwa badj 'Lokasyon Verifye'."
  end

  # ── GET /business/check_slug (AJAX) ──
  def check_slug
    slug = params[:slug].to_s.strip.downcase.gsub(/[^a-z0-9\-]/, "")

    if slug.blank? || slug.length < 3
      render json: { available: false, message: "Minimum 3 karakte." }
    elsif Business.where.not(user_id: current_user.id).exists?(slug: slug)
      render json: { available: false, message: "Slug sa a deja pran." }
    else
      render json: { available: true, message: "Disponib!" }
    end
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

  # ── GET /b/:slug/products — Public product listing (no auth) ──
  def product_index
    @business = Business.find_by!(slug: params[:slug])
    @products = @business.products.active.ordered
    @owner = @business.user

    render layout: "application"
  rescue ActiveRecord::RecordNotFound
    redirect_to root_path, alert: "Biznis sa a pa egziste."
  end

  # ── GET /b/:slug/p/:token — Product detail page (no auth) ──
  def product_show
    @business = Business.find_by!(slug: params[:slug])
    @product = @business.products.active.find_by!(token: params[:token])
    @owner = @business.user

    render layout: "application"
  rescue ActiveRecord::RecordNotFound
    redirect_to root_path, alert: "Pwodui sa a pa egziste."
  end

  # ── GET /b/:slug/pay — Direct payment page (no auth, rate limited) ──
  def pay_page
    @business = Business.find_by!(slug: params[:slug])
    @owner = @business.user
    @asset = %w[htg usd].include?(params[:asset]) ? params[:asset] : "htg"
    @amount = params[:amount]
    @note = params[:note]
    @cart_items = JSON.parse(params[:cart_items]) rescue nil if params[:cart_items].present?
    # Tips: payment link overrides business default; direct visit uses business setting
    @show_tips = if params[:tips].present?
                   params[:tips] == "1"  # Link override (can enable OR disable)
                 else
                   @business.tippable?   # Direct visit uses business profile setting
                 end

    render layout: "application"
  rescue ActiveRecord::RecordNotFound
    redirect_to root_path, alert: "Biznis sa a pa egziste."
  end

  # ── POST /b/:slug/pay — Quick pay: create transfer directly (logged-in users) ──
  def quick_pay
    @business = Business.find_by!(slug: params[:slug])
    @owner = @business.user

    amount = params[:amount].to_f
    asset = %w[htg usd].include?(params[:asset]) ? params[:asset] : "htg"
    note = params[:note].to_s

    if amount <= 0
      redirect_to pay_business_path(@business.slug, amount: params[:amount], asset: asset, note: note), alert: "Montan pa valid."
      return
    end

    unless current_user.transfer_pin_set?
      redirect_to pay_business_path(@business.slug, amount: params[:amount], asset: asset, note: note), alert: "Ou dwe kreye yon PIN transfè anvan."
      return
    end

    @transfer = current_user.transfers.new(amount: amount, note: note, asset: asset)
    @transfer.receiver_cashtag = @owner.cashtag
    @transfer.business_id = @business.id
    @transfer.payout_method = "wallet"
    @transfer.receiver_name = @owner.display_name

    # Resolve receiver user for wallet-to-wallet
    found = User.find_by("LOWER(cashtag) = ?", @owner.cashtag.downcase)
    @transfer.receiver_email = found.email if found

    if @transfer.save
      redirect_to transfer_path(@transfer)
    else
      redirect_to pay_business_path(@business.slug, amount: params[:amount], asset: asset, note: note),
        alert: @transfer.errors.full_messages.first || "Pa kapab kreye transfè a."
    end
  rescue ActiveRecord::RecordNotFound
    redirect_to root_path, alert: "Biznis sa a pa egziste."
  end

  # ── GET /business/button — Embed code generator (auth) ──
  def button
    redirect_to new_business_path and return unless @business
  end

  # ── GET /button/:slug.js — Public JS widget ──
  def button_js
    @business = Business.find_by!(slug: params[:slug])

    js = <<~JS
      (function() {
        var script = document.currentScript;
        var slug = #{@business.slug.to_json};
        var amount = script.getAttribute('data-amount') || '';
        var note = script.getAttribute('data-note') || '';
        var asset = script.getAttribute('data-asset') || 'htg';
        var text = script.getAttribute('data-text') || 'Zèllus Pay';
        var baseUrl = #{root_url.to_json} + 'b/' + slug + '/pay';
        var params = [];
        if (amount) params.push('amount=' + encodeURIComponent(amount));
        if (note) params.push('note=' + encodeURIComponent(note));
        if (asset) params.push('asset=' + encodeURIComponent(asset));
        var url = baseUrl + (params.length ? '?' + params.join('&') : '');

        var btn = document.createElement('a');
        btn.href = url;
        btn.target = '_blank';
        btn.rel = 'noopener';
        btn.textContent = text;
        btn.style.cssText = 'display:inline-flex;align-items:center;gap:8px;padding:14px 28px;background:#2E2E38;color:#C5A059;font-family:-apple-system,BlinkMacSystemFont,sans-serif;font-size:15px;font-weight:700;border-radius:12px;text-decoration:none;border:2px solid rgba(197,160,89,0.3);cursor:pointer;transition:all 0.2s;';
        btn.onmouseover = function() { this.style.background = '#3a3a48'; this.style.borderColor = '#C5A059'; };
        btn.onmouseout = function() { this.style.background = '#2E2E38'; this.style.borderColor = 'rgba(197,160,89,0.3)'; };

        var icon = document.createElement('img');
        icon.src = #{ActionController::Base.helpers.asset_url("zellus_square.png").to_json};
        icon.style.cssText = 'width:20px;height:20px;border-radius:4px;';
        btn.prepend(icon);

        script.parentNode.insertBefore(btn, script);
      })();
    JS

    render plain: js, content_type: "application/javascript"
  rescue ActiveRecord::RecordNotFound
    render plain: "// Business not found", content_type: "application/javascript", status: :not_found
  end

  private

  def set_business
    @business = current_user.business
  end

  def business_params
    params.require(:business).permit(
      :name, :slug, :category, :subcategory, :description,
      :department, :arrondissement, :commune, :section,
      :address, :phone, :email,
      :website, :hours, :tax_id, :auto_settle, :logo, :tippable,
      accepted_currencies: [], social_media: {}
    )
  end
end
