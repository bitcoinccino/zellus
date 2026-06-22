class Admin::InviteCodesController < Admin::BaseController
  def index
    @invite_codes = InviteCode.includes(:creator).order(created_at: :desc)
    @new_invite_code = InviteCode.new(region: "Côtes de Fer", max_uses: 1)
    @nested_addresses = InviteCode::NESTED_ADDRESSES
    @total_signups = User.where.not(invite_code_id: nil).count
  end

  def create
    # PIN verification
    unless current_user.verify_transfer_pin(params[:transfer_pin])
      redirect_to admin_invite_codes_path, alert: "PIN transfè pa kòrèk."
      return
    end

    # Rate limiting: max 100 codes per hour
    recent_count = InviteCode.where(creator: current_user)
                             .where("created_at > ?", 1.hour.ago)
                             .count
    if recent_count >= 100
      redirect_to admin_invite_codes_path, alert: "Limit atenn: ou pa ka kreye plis ke 100 kòd pa èdtan."
      return
    end

    batch_size = params[:batch_size].to_i.clamp(1, 50)
    region = params[:invite_code][:region]
    max_uses = params[:invite_code][:max_uses].to_i
    label = params[:invite_code][:label].presence
    expires_in = params[:expires_in].to_i

    # Enforce rate limit on actual batch too
    allowed = [ batch_size, 100 - recent_count ].min
    created = 0
    allowed.times do
      code = InviteCode.new(
        region: region,
        max_uses: max_uses,
        label: label,
        creator: current_user,
        expires_at: expires_in > 0 ? expires_in.days.from_now : nil
      )
      created += 1 if code.save
    end

    redirect_to admin_invite_codes_path, notice: "#{created} kòd envitasyon kreye pou #{region}."
  end

  def toggle
    code = InviteCode.find(params[:id])
    code.update!(active: !code.active?)
    redirect_to admin_invite_codes_path, notice: "Kòd #{code.code} #{code.active? ? 'aktive' : 'dezaktive'}."
  end

  def expire
    code = InviteCode.find(params[:id])
    code.update!(expires_at: Time.current)
    redirect_to admin_invite_codes_path, notice: "Kòd #{code.code} ekspire."
  end

  def destroy
    code = InviteCode.find(params[:id])
    code_name = code.code
    code.destroy!
    redirect_to admin_invite_codes_path, notice: "Kòd #{code_name} efase."
  end
end
