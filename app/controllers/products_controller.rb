class ProductsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_business
  before_action :set_product, only: [:edit, :update, :destroy]

  # ── GET /business/products.json — list products for payment link picker ──
  def index
    products = @business.products.active.ordered
    render json: products.map { |p|
      {
        id: p.id,
        name: p.name,
        price: p.price.to_f,
        asset: p.asset,
        asset_label: p.asset_label,
        image_url: p.image.attached? ? Rails.application.routes.url_helpers.url_for(p.image) : nil
      }
    }
  end

  # ── GET /business/products/new ──
  def new
    @product = @business.products.new
  end

  # ── POST /business/products ──
  def create
    @product = @business.products.new(product_params)
    @product.position ||= @business.products.count + 1

    if @product.save
      redirect_to business_path, notice: "Pwodui \"#{@product.name}\" ajoute avèk siksè!"
    else
      render :new, status: :unprocessable_entity
    end
  end

  # ── GET /business/products/:id/edit ──
  def edit
  end

  # ── PATCH /business/products/:id ──
  def update
    if @product.update(product_params)
      redirect_to business_path, notice: "Pwodui mete ajou avèk siksè!"
    else
      render :edit, status: :unprocessable_entity
    end
  end

  # ── DELETE /business/products/:id ──
  def destroy
    @product.destroy
    redirect_to business_path, notice: "Pwodui efase."
  end

  private

  def set_business
    @business = current_user.business
    unless @business
      redirect_to new_business_path, alert: "Ou bezwen kreye yon biznis anvan."
    end
  end

  def set_product
    @product = @business.products.find(params[:id])
  end

  def product_params
    params.require(:product).permit(:name, :price, :asset, :description, :position, :active, :image, :product_type, :stock)
  end
end
