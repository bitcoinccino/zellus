module ApplicationHelper
  # Convert raw technical failure reasons into user-friendly Kreyòl messages
  def friendly_failure_reason(reason)
    return "Erè enkoni." if reason.blank?

    r = reason.to_s.downcase
    if r.include?("transfer amount exceeds balance") || r.include?("insufficient")
      "Trezò pa gen ase USD pou trete transfè sa a. Lajan ou retounen otomatikman."
    elsif r.include?("nonce too low") || r.include?("nonce already used")
      "Erè rezo — tranzaksyon an te deja trete. Tanpri verifye balans ou."
    elsif r.include?("gas") && r.include?("exceed")
      "Frè rezo twò wo pou trete transfè sa a kounye a. Eseye ankò pita."
    elsif r.include?("timeout") || r.include?("timed out")
      "Koneksyon ak rezo Base te ekspire. Eseye ankò pita."
    elsif r.include?("reverted") || r.include?("revert")
      "Tranzaksyon an pa t kapab konplete sou rezo Base. Lajan ou retounen otomatikman."
    elsif r.include?("consent") || r.include?("bonid")
      "Verifikasyon BonID obligatwa pou montan sa a."
    else
      "Transfè pa t kapab konplete. Kontakte sipò si pwoblèm nan pèsiste."
    end
  end

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

  # Inline currency icon (Remix Icons) — use for labels, badges, input suffixes
  # currency_icon("htg")       => <i class="ri-money-cny-circle-line"></i>
  # currency_icon("usd")       => <i class="ri-money-dollar-circle-line"></i>
  # currency_icon("htg", 14)   => <i ... style="font-size: 14px;"></i>
  # Currency text label: currency_label("htg") => "HTG", currency_label("usd") => "USD"
  def currency_label(asset, _size = nil)
    asset.to_s == "usd" ? "USD" : "HTG"
  end

  # Generate an inline SVG QR code for the given text
  # color: hex without # (default haiti-gold)
  # size: pixel width/height for the rendered SVG (default 160)
  def qr_svg(text, color: "000000", size: 200, logo: true)
    qrcode = RQRCode::QRCode.new(text, level: :h)
    modules = qrcode.modules
    mod_count = modules.length
    quiet = 4 # QR spec quiet zone
    total = mod_count + quiet * 2

    rects = []
    modules.each_with_index do |row, r|
      row.each_with_index do |dark, c|
        next unless dark
        rects << %(<rect x="#{c + quiet}" y="#{r + quiet}" width="1" height="1"/>)
      end
    end

    svg = %(<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="#{size}" height="#{size}" viewBox="0 0 #{total} #{total}" shape-rendering="crispEdges">) +
          %(<rect width="#{total}" height="#{total}" fill="white"/>) +
          %(<g fill="##{color}">#{rects.join}</g>)

    if logo
      logo_dim = mod_count * 0.14
      lx = quiet + (mod_count - logo_dim) / 2.0
      pad = logo_dim * 0.1
      img_size = logo_dim * 0.8
      img_url = ActionController::Base.helpers.asset_path("zellus_square.png")
      svg += %(<rect x="#{lx}" y="#{lx}" width="#{logo_dim}" height="#{logo_dim}" rx="#{logo_dim * 0.18}" fill="white"/>)
      svg += %(<image href="#{img_url}" xlink:href="#{img_url}" x="#{lx + pad}" y="#{lx + pad}" width="#{img_size}" height="#{img_size}"/>)
    end

    svg += %(</svg>)
    svg.html_safe
  end
end
