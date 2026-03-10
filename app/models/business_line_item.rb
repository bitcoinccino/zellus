class BusinessLineItem < ApplicationRecord
  belongs_to :transfer
  belongs_to :product

  validates :name, :quantity, :unit_price, presence: true

  before_save :calculate_total

  private

  def calculate_total
    self.line_total = quantity * unit_price
  end
end
