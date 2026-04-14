require "ruby-vips"
Prawn::Fonts::AFM.hide_m17n_warning = true

class AgentKitService
  # ── Brand palette ──
  CHARCOAL = "2E2E38"
  GOLD     = "C5A059"
  OLIVE    = "5D6345"
  CREAM    = "F7F4E3"
  MINT     = "E8EDE0"
  WHITE    = "FFFFFF"
  LIGHT_BG = "F5F3EC"   # Subtle warm gray for premium background
  SHADOW   = "D6D3CA"   # Soft shadow color

  BASE_URL  = ENV.fetch("APP_BASE_URL", "https://zellus.app")
  LOGO_PATH = Rails.root.join("app", "assets", "images", "zellus_square.png")
  FONTS_DIR = Rails.root.join("app", "assets", "fonts")

  def self.generate_pdf(business)
    new(business).generate
  end

  def initialize(business)
    @business  = business
    @slug      = business.slug
    @name      = business.name
    @cashtag   = "$#{@slug}"
    @location  = [business.commune, business.department].compact.join(", ")
    @qr_url    = "#{BASE_URL}/b/#{@slug}/pay"
    @logo_data = business.logo.attached? ? business.logo.download : nil
  rescue => e
    Rails.logger.error "Agent kit logo download error: #{e.message}"
    @logo_data = nil
  end

  def generate
    pdf = Prawn::Document.new(page_size: "LETTER", margin: 0)

    # Register custom fonts for UTF-8 support (è accent)
    pdf.font_families.update(
      "SpaceGrotesk" => {
        normal: FONTS_DIR.join("SpaceGrotesk-Regular.ttf").to_s,
        bold:   FONTS_DIR.join("SpaceGrotesk-Bold.ttf").to_s
      },
      "Jakarta" => {
        normal:    FONTS_DIR.join("PlusJakartaSans-Regular.ttf").to_s,
        bold:      FONTS_DIR.join("PlusJakartaSans-Bold.ttf").to_s,
        semibold:  FONTS_DIR.join("PlusJakartaSans-SemiBold.ttf").to_s
      }
    )

    # Set default font for full UTF-8 support
    pdf.font "Jakarta"

    render_poster(pdf)
    pdf.start_new_page
    render_counter_sticker(pdf)

    pdf.render
  end

  private

  PAGE_W = 612.0  # Letter width in points
  PAGE_H = 792.0  # Letter height in points

  # ══════════════════════════════════════════════════════════════
  # PAGE 1: WALL POSTER — Professional "Fintech Card" layout
  # Visual anchor = QR code on raised white card
  # ══════════════════════════════════════════════════════════════
  def render_poster(pdf)
    w = PAGE_W
    m = 50  # margin

    # ── Premium background with subtle dot pattern ──
    pdf.fill_color LIGHT_BG
    pdf.fill_rectangle [0, PAGE_H], w, PAGE_H

    # Subtle dot pattern for premium texture
    pdf.fill_color SHADOW
    (0..w.to_i).step(24) do |x|
      (0..PAGE_H.to_i).step(24) do |y|
        pdf.fill_circle [x, y], 0.5
      end
    end

    # ── Top: Charcoal header band ──
    header_h = 80
    pdf.fill_color CHARCOAL
    pdf.fill_rectangle [0, PAGE_H], w, header_h

    # Zèllus logo (small, top-left)
    if File.exist?(LOGO_PATH)
      pdf.image LOGO_PATH.to_s, fit: [32, 32],
        at: [m, PAGE_H - 24]
    end

    # Brand name (small, beside logo) — Space Grotesk for branding
    pdf.fill_color GOLD
    pdf.font("SpaceGrotesk", style: :bold) do
      pdf.text_box "Z\u00E8llus",
        at: [m + 40, PAGE_H - 24],
        width: 200,
        height: 32,
        size: 18,
        valign: :center
    end

    # "Ajan Verifye" badge (top-right)
    badge_w = 100
    badge_h = 26
    badge_x = w - m - badge_w
    badge_y = PAGE_H - 27
    pdf.fill_color GOLD
    pdf.fill_rounded_rectangle [badge_x, badge_y], badge_w, badge_h, 13
    pdf.fill_color CHARCOAL
    pdf.text_box "Ajan Verifye",
      at: [badge_x, badge_y],
      width: badge_w,
      height: badge_h,
      size: 9,
      style: :bold,
      align: :center,
      valign: :center

    # ── Gold accent line ──
    accent_y = PAGE_H - header_h
    pdf.stroke_color GOLD
    pdf.line_width = 3
    pdf.stroke_horizontal_line(0, w, at: accent_y)

    # ── Main headline ──
    head_y = accent_y - 35
    pdf.fill_color CHARCOAL
    pdf.font("SpaceGrotesk", style: :bold) do
      pdf.text_box "Ajan Z\u00E8llus Isit la",
        at: [m, head_y],
        width: w - (m * 2),
        height: 42,
        size: 34,
        align: :center
    end

    sub_y = head_y - 45
    pdf.fill_color OLIVE
    pdf.text_box "Depoze lajan kach nan kont Z\u00E8llus ou isit la.",
      at: [m, sub_y],
      width: w - (m * 2),
      height: 20,
      size: 13,
      align: :center

    # ══════════════════════════════════════════════════════════
    # THE VISUAL ANCHOR: QR Code on a raised white card
    # ══════════════════════════════════════════════════════════
    card_w = 300
    card_h = 320
    card_x = (w - card_w) / 2
    card_y = sub_y - 30

    # Drop shadow (offset 3px down-right)
    pdf.fill_color SHADOW
    pdf.fill_rounded_rectangle [card_x + 4, card_y - 4], card_w, card_h, 16

    # White card
    pdf.fill_color WHITE
    pdf.fill_rounded_rectangle [card_x, card_y], card_w, card_h, 16

    # Mint border on card
    pdf.stroke_color MINT
    pdf.line_width = 2
    pdf.stroke_rounded_rectangle [card_x, card_y], card_w, card_h, 16

    # QR Code centered inside card
    qr_png = generate_qr_png(@qr_url, logo_data: @logo_data, size: 560, logo_size: 110)
    if qr_png
      qr_display = 230
      qr_x = card_x + (card_w - qr_display) / 2
      qr_y = card_y - 20
      pdf.image StringIO.new(qr_png), fit: [qr_display, qr_display],
        at: [qr_x, qr_y]
    end

    # Scan instruction with arrow indicator
    scan_y = card_y - 260
    pdf.fill_color OLIVE
    pdf.text_box "Eskane pou depoze lajan",
      at: [card_x, scan_y],
      width: card_w,
      height: 18,
      size: 11,
      align: :center,
      style: :semibold

    # Small upward arrow pointing to QR
    arrow_y = scan_y + 22
    arrow_cx = w / 2
    pdf.stroke_color OLIVE
    pdf.line_width = 1.5
    pdf.stroke_line [arrow_cx, arrow_y], [arrow_cx, arrow_y + 10]
    pdf.stroke_line [arrow_cx - 4, arrow_y + 6], [arrow_cx, arrow_y + 10]
    pdf.stroke_line [arrow_cx + 4, arrow_y + 6], [arrow_cx, arrow_y + 10]

    # ══════════════════════════════════════════════════════════
    # BOTTOM SECTION: Merchant identity
    # ══════════════════════════════════════════════════════════
    bottom_y = card_y - card_h - 25

    # CashTag pill (high contrast)
    tag_w = 280
    tag_h = 50
    tag_x = (w - tag_w) / 2
    pdf.fill_color CHARCOAL
    pdf.fill_rounded_rectangle [tag_x, bottom_y], tag_w, tag_h, 25
    pdf.fill_color WHITE
    pdf.text_box @cashtag,
      at: [tag_x, bottom_y],
      width: tag_w,
      height: tag_h,
      size: 24,
      style: :bold,
      align: :center,
      valign: :center

    # Business name (large, bold)
    name_y = bottom_y - tag_h - 12
    pdf.fill_color CHARCOAL
    pdf.text_box @name,
      at: [m, name_y],
      width: w - (m * 2),
      height: 28,
      size: 22,
      style: :bold,
      align: :center

    # Location pill badge
    if @location.present?
      loc_w = [pdf.width_of(@location, size: 9) + 24, 200].min
      loc_x = (w - loc_w) / 2
      loc_y = name_y - 28
      loc_h = 22

      pdf.fill_color MINT
      pdf.fill_rounded_rectangle [loc_x, loc_y], loc_w, loc_h, 11
      pdf.fill_color OLIVE
      pdf.text_box @location,
        at: [loc_x, loc_y],
        width: loc_w,
        height: loc_h,
        size: 9,
        style: :bold,
        align: :center,
        valign: :center
    end

    # ══════════════════════════════════════════════════════════
    # "KIJAN SA MACHE?" — 3-step how-it-works
    # ══════════════════════════════════════════════════════════
    steps_y = 95
    step_w = 140
    steps_total = (step_w * 3) + 40
    steps_x = (w - steps_total) / 2

    # Divider line above steps
    pdf.stroke_color SHADOW
    pdf.line_width = 0.5
    pdf.stroke_horizontal_line(m + 40, w - m - 40, at: steps_y + 25)

    pdf.fill_color OLIVE
    pdf.text_box "Kijan sa mache?",
      at: [m, steps_y + 20],
      width: w - (m * 2),
      height: 14,
      size: 8,
      style: :bold,
      align: :center

    steps = [
      { num: "1", label: "Eskane k\u00F2d la" },
      { num: "2", label: "Antre montan an" },
      { num: "3", label: "Konfime peman" }
    ]

    steps.each_with_index do |step, i|
      sx = steps_x + (i * (step_w + 20))

      # Circle with number
      circle_x = sx + step_w / 2
      circle_y = steps_y - 8
      pdf.fill_color GOLD
      pdf.fill_circle [circle_x, circle_y], 12
      pdf.fill_color CHARCOAL
      pdf.text_box step[:num],
        at: [circle_x - 12, circle_y + 6],
        width: 24,
        height: 14,
        size: 10,
        style: :bold,
        align: :center,
        valign: :center

      # Step label
      pdf.fill_color CHARCOAL
      pdf.text_box step[:label],
        at: [sx, circle_y - 18],
        width: step_w,
        height: 14,
        size: 9,
        align: :center
    end

    # Footer: Commission badge + URL
    pdf.fill_color OLIVE
    pdf.text_box "2% komisyon imedyat  |  z\u00E8llus.app",
      at: [m, 22],
      width: w - (m * 2),
      height: 14,
      size: 8,
      align: :center
  end

  # ══════════════════════════════════════════════════════════════
  # PAGE 2: COUNTER STICKER — Compact cut-out card
  # Designed to be cut and placed on counter/register
  # ══════════════════════════════════════════════════════════════
  def render_counter_sticker(pdf)
    w = PAGE_W

    # Light background
    pdf.fill_color LIGHT_BG
    pdf.fill_rectangle [0, PAGE_H], w, PAGE_H

    # Instruction at top
    pdf.fill_color OLIVE
    pdf.text_box "DEKOUPE LONG LIGN NAN EPI KOLE SOU KONTWA OU",
      at: [40, PAGE_H - 30],
      width: w - 80,
      height: 16,
      size: 9,
      style: :bold,
      align: :center

    # ── Dashed cut line (top) ──
    cut_top_y = PAGE_H - 55
    pdf.dash(5, space: 3)
    pdf.stroke_color OLIVE
    pdf.line_width = 1
    pdf.stroke_horizontal_line(30, w - 30, at: cut_top_y)
    pdf.undash

    # ══════════════════════════════════════════════════════════
    # THE STICKER CARD
    # ══════════════════════════════════════════════════════════
    sticker_w = 340
    sticker_h = 520
    sticker_x = (w - sticker_w) / 2
    sticker_y = cut_top_y - 20

    # Card shadow
    pdf.fill_color SHADOW
    pdf.fill_rounded_rectangle [sticker_x + 3, sticker_y - 3], sticker_w, sticker_h, 20

    # Card background
    pdf.fill_color WHITE
    pdf.fill_rounded_rectangle [sticker_x, sticker_y], sticker_w, sticker_h, 20

    # Mint border
    pdf.stroke_color MINT
    pdf.line_width = 2.5
    pdf.stroke_rounded_rectangle [sticker_x, sticker_y], sticker_w, sticker_h, 20

    # ── Charcoal header inside sticker ──
    header_h = 75
    # Clip header to card shape with inner rectangle
    pdf.fill_color CHARCOAL
    pdf.fill_rounded_rectangle [sticker_x + 2, sticker_y - 2], sticker_w - 4, header_h, 18

    # Zèllus logo (small) in header
    if File.exist?(LOGO_PATH)
      logo_size = 28
      pdf.image LOGO_PATH.to_s, fit: [logo_size, logo_size],
        at: [sticker_x + (sticker_w - logo_size) / 2, sticker_y - 10]
    end

    # "NOU AKSEPTE Zèllus"
    pdf.fill_color GOLD
    pdf.font("SpaceGrotesk", style: :bold) do
      pdf.text_box "NOU AKSEPTE",
        at: [sticker_x, sticker_y - 44],
        width: sticker_w,
        height: 14,
        size: 9,
        align: :center

      pdf.text_box "Z\u00E8llus",
        at: [sticker_x, sticker_y - 56],
        width: sticker_w,
        height: 22,
        size: 18,
        align: :center
    end

    # ── QR Code on inner white area ──
    content_y = sticker_y - header_h - 15

    # Inner QR card (raised effect)
    qr_card_size = 200
    qr_card_x = sticker_x + (sticker_w - qr_card_size) / 2

    pdf.fill_color "F0EDE4"
    pdf.fill_rounded_rectangle [qr_card_x + 2, content_y - 2], qr_card_size, qr_card_size, 12
    pdf.fill_color WHITE
    pdf.fill_rounded_rectangle [qr_card_x, content_y], qr_card_size, qr_card_size, 12
    pdf.stroke_color MINT
    pdf.line_width = 1
    pdf.stroke_rounded_rectangle [qr_card_x, content_y], qr_card_size, qr_card_size, 12

    qr_png = generate_qr_png(@qr_url, logo_data: @logo_data, size: 480, logo_size: 90)
    if qr_png
      qr_display = 180
      qr_x = qr_card_x + (qr_card_size - qr_display) / 2
      qr_y = content_y - 10
      pdf.image StringIO.new(qr_png), fit: [qr_display, qr_display],
        at: [qr_x, qr_y]
    end

    # "Eskane kòd la"
    scan_y = content_y - qr_card_size - 12
    pdf.fill_color OLIVE
    pdf.text_box "Eskane k\u00F2d la",
      at: [sticker_x, scan_y],
      width: sticker_w,
      height: 14,
      size: 10,
      align: :center

    # CashTag pill
    tag_w = 200
    tag_h = 38
    tag_x = (w - tag_w) / 2
    tag_y = scan_y - 20
    pdf.fill_color CHARCOAL
    pdf.fill_rounded_rectangle [tag_x, tag_y], tag_w, tag_h, 19
    pdf.fill_color GOLD
    pdf.text_box @cashtag,
      at: [tag_x, tag_y],
      width: tag_w,
      height: tag_h,
      size: 18,
      style: :bold,
      align: :center,
      valign: :center

    # ── Merchant identity at bottom ──
    biz_y = tag_y - tag_h - 20

    # Business logo (small circle effect)
    if @logo_data
      begin
        logo_temp = Tempfile.new(["biz_logo", ".bin"])
        logo_temp.binmode
        logo_temp.write(@logo_data)
        logo_temp.close
        logo_display = 36
        logo_x = (w - logo_display) / 2
        pdf.image logo_temp.path, fit: [logo_display, logo_display],
          at: [logo_x, biz_y]
        biz_y -= (logo_display + 6)
        logo_temp.close!
      rescue => e
        Rails.logger.error "Sticker logo error: #{e.message}"
      end
    end

    pdf.fill_color CHARCOAL
    pdf.text_box @name,
      at: [sticker_x, biz_y],
      width: sticker_w,
      height: 18,
      size: 14,
      style: :bold,
      align: :center

    # Location pill
    if @location.present?
      loc_w = [pdf.width_of(@location, size: 8) + 20, 180].min
      loc_x = (w - loc_w) / 2
      loc_y = biz_y - 22
      loc_h = 20

      pdf.fill_color MINT
      pdf.fill_rounded_rectangle [loc_x, loc_y], loc_w, loc_h, 10
      pdf.fill_color OLIVE
      pdf.text_box @location,
        at: [loc_x, loc_y],
        width: loc_w,
        height: loc_h,
        size: 8,
        style: :bold,
        align: :center,
        valign: :center
    end

    # ── Dashed cut line (bottom) ──
    cut_bottom_y = sticker_y - sticker_h - 20
    pdf.dash(5, space: 3)
    pdf.stroke_color OLIVE
    pdf.line_width = 1
    pdf.stroke_horizontal_line(30, w - 30, at: cut_bottom_y)
    pdf.undash

    pdf.fill_color OLIVE
    pdf.text_box ">>",
      at: [20, cut_bottom_y + 5],
      width: 20,
      height: 12,
      size: 8
  end

  # ══════════════════════════════════════════════════════════════
  # QR Code PNG generation with business logo overlay
  # ══════════════════════════════════════════════════════════════
  def generate_qr_png(text, logo_data: nil, size: 480, logo_size: 90)
    qrcode = RQRCode::QRCode.new(text, level: :h)
    qr_image = qrcode.as_png(
      border_modules: 2,
      module_px_size: 12,
      size: size,
      color: "C5A059",
      fill: "FFFFFF"
    )

    if logo_data
      overlay_logo_on_qr!(qr_image, logo_data, logo_size)
    end

    qr_image.to_s
  rescue => e
    Rails.logger.error "QR code generation failed: #{e.message}"
    nil
  end

  # Composites a logo image into the center of a ChunkyPNG QR code image
  def overlay_logo_on_qr!(qr_image, logo_data, logo_target = 90)
    padding = 12

    # Use Vips to convert any image format to PNG and resize
    logo_temp = Tempfile.new(["logo_src", ".bin"])
    logo_temp.binmode
    logo_temp.write(logo_data)
    logo_temp.close

    vips_img = Vips::Image.new_from_file(logo_temp.path)

    # Flatten alpha onto white background for clean compositing
    if vips_img.bands == 4
      vips_img = vips_img.flatten(background: [255, 255, 255])
    end

    scale = logo_target.to_f / [vips_img.width, vips_img.height].max
    vips_img = vips_img.resize(scale)

    png_temp = Tempfile.new(["logo_png", ".png"])
    vips_img.pngsave(png_temp.path)

    logo_png = ChunkyPNG::Image.from_file(png_temp.path)

    # White circle background with generous padding
    bg_size = logo_target + (padding * 2)
    radius = bg_size / 2.0
    center = bg_size / 2.0
    cx = (qr_image.width - bg_size) / 2
    cy = (qr_image.height - bg_size) / 2

    # Draw white circle behind logo
    bg_size.times do |x|
      bg_size.times do |y|
        dist = Math.sqrt((x - center) ** 2 + (y - center) ** 2)
        qr_image[cx + x, cy + y] = ChunkyPNG::Color::WHITE if dist <= radius
      end
    end

    # Crop the logo itself into a circle
    logo_radius = [logo_png.width, logo_png.height].min / 2.0
    logo_cx = logo_png.width / 2.0
    logo_cy = logo_png.height / 2.0
    logo_png.height.times do |y|
      logo_png.width.times do |x|
        dist = Math.sqrt((x - logo_cx) ** 2 + (y - logo_cy) ** 2)
        if dist > logo_radius
          logo_png[x, y] = ChunkyPNG::Color::TRANSPARENT
        end
      end
    end

    # Composite the logo centered
    logo_offset_x = cx + padding + (logo_target - logo_png.width) / 2
    logo_offset_y = cy + padding + (logo_target - logo_png.height) / 2
    qr_image.compose!(logo_png, logo_offset_x, logo_offset_y)
  rescue => e
    Rails.logger.error "QR logo overlay error: #{e.message}"
  ensure
    logo_temp&.close!
    png_temp&.close!
  end
end
