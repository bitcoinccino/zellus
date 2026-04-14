class Product < ApplicationRecord
  belongs_to :business
  has_many :business_line_items
  has_one_attached :image

  enum :asset, { htg: "htg", usd: "usd" }
  enum :product_type, { good: "good", service: "service" }, prefix: true

  validates :name, :price, presence: true
  validates :asset, presence: true
  validates :stock, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  has_secure_token :token # For unique QR code generation

  scope :active, -> { where(active: true).order(:position) }
  scope :ordered, -> { order(:position) }

  def asset_label
    asset == "usd" ? "USD" : "HTG"
  end

  # Goods get a quantity picker; services are always qty 1
  def allows_quantity?
    product_type_good?
  end

  # nil stock = unlimited; 0 = sold out
  def max_quantity
    return 1 unless allows_quantity?
    stock.nil? ? 99 : stock
  end

  def in_stock?
    stock.nil? || stock > 0
  end

  def record_sale!(quantity)
    increment!(:sold_count, quantity)
    increment!(:total_revenue, price * quantity)
  end
end
