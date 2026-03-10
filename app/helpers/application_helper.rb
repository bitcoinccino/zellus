module ApplicationHelper
  # Returns the correct Basescan URL based on the chain configured in the worker
  def basescan_tx_url(tx_hash)
    base = CryptoTransferWorker::CHAIN_ID == 8453 ? "https://basescan.org" : "https://sepolia.basescan.org"
    "#{base}/tx/#{tx_hash}"
  end

  # Truncate (floor) a balance to N decimals — never rounds up so users
  # don't think they have more than they actually do.
  def truncated_balance(amount, decimals = 2)
    val = amount.to_f
    factor = 10**decimals
    (val * factor).floor / factor.to_f
  end

  # ── Brand logos (from app/assets/images/) ──
  # SVGs have a non-square viewBox (48×55.92) so we wrap in a circular
  # container with overflow:hidden to clip a perfect circle.

  def brand_logo(file, alt:, size: 28)
    img = image_tag(file, style: "width: 120%; height: 120%; object-fit: cover; margin: -10%;", alt: alt)
    content_tag(:span, img, style: "display: inline-flex; align-items: center; justify-content: center; width: #{size}px; height: #{size}px; border-radius: 50%; overflow: hidden; flex-shrink: 0;")
  end

  # HTG (Goud Ayisyen) logo
  def htg_logo_svg(size: 28)
    brand_logo("htg.svg", alt: "HTG", size: size)
  end

  # MonCash logo
  def moncash_logo_svg(size: 28)
    brand_logo("moncash.svg", alt: "MonCash", size: size)
  end

  # USD logo
  def usd_logo(size: 28)
    brand_logo("usd.svg", alt: "USD", size: size)
  end

  # Base (Coinbase L2) logo
  def base_logo_svg(size: 28)
    brand_logo("base.svg", alt: "Base", size: size)
  end

  # Unibank Haiti logo
  def unibank_logo_svg(size: 28)
    brand_logo("unibank.svg", alt: "Unibank", size: size)
  end

  # ETH on Base logo
  def eth_base_logo_svg(size: 28)
    brand_logo("eth-base.svg", alt: "ETH", size: size)
  end

  # WBTC on Base logo
  def wbtc_base_logo_svg(size: 28)
    brand_logo("wbtc-on-base.svg", alt: "WBTC", size: size)
  end

  # ── Tokenized Stock logos (xStocks on Base) ──
  def tslax_logo(size: 28)
    brand_logo("tesla.png", alt: "TSLAX", size: size)
  end

  def nvdax_logo(size: 28)
    brand_logo("nvidia.png", alt: "NVDAX", size: size)
  end

  def aaplx_logo(size: 28)
    brand_logo("apple.png", alt: "AAPLX", size: size)
  end

  def coinx_logo(size: 28)
    brand_logo("coinbase.png", alt: "COINX", size: size)
  end

  def googlx_logo(size: 28)
    brand_logo("google.png", alt: "GOOGLX", size: size)
  end

  # Generate an inline SVG QR code for the given text
  # color: hex without # (default haiti-gold)
  def qr_svg(text, color: "C5A059")
    qrcode = RQRCode::QRCode.new(text)
    qrcode.as_svg(
      color: color,
      shape_rendering: "crispEdges",
      module_size: 4,
      standalone: true,
      use_path: true,
      viewbox: true
    ).html_safe
  end
end
