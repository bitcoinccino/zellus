class Product < ApplicationRecord
  belongs_to :business
  has_many :business_line_items
  has_one_attached :image

  validates :name, :price, presence: true
  has_secure_token :token # For unique QR code generation

  scope :active, -> { where(active: true).order(:position) }
  scope :ordered, -> { order(:position) }

  def record_sale!(quantity)
    increment!(:sold_count, quantity)
    increment!(:total_revenue, price * quantity)
  end
end
