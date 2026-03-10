# frozen_string_literal: true

class BlockchainDepositMonitor < ApplicationRecord
  validates :name, presence: true, uniqueness: true
  validates :last_processed_block, numericality: { greater_than_or_equal_to: 0 }
end
