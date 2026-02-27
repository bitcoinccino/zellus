module ApplicationHelper
  # Returns the correct Basescan URL based on the chain configured in the worker
  def basescan_tx_url(tx_hash)
    base = CryptoTransferWorker::CHAIN_ID == 8453 ? "https://basescan.org" : "https://sepolia.basescan.org"
    "#{base}/tx/#{tx_hash}"
  end
end
