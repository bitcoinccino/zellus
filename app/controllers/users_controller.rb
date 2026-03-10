class UsersController < ApplicationController
  before_action :authenticate_user!, only: [:lookup]
  skip_before_action :require_cashtag!, only: [:setup_cashtag, :save_cashtag, :check_cashtag]

  # GET /users/check_cashtag?cashtag=xxx (JSON)
  def check_cashtag
    tag = params[:cashtag].to_s.strip.downcase.delete_prefix("$")

    if tag.blank? || !tag.match?(/\A[a-zA-Z0-9]{5,20}\z/)
      render json: { available: false, message: "Dwe 5-20 karaktè alfanimerik." }
    elsif User.where("LOWER(cashtag) = ?", tag).exists?
      render json: { available: false, message: "Zellustag sa a deja pran." }
    else
      render json: { available: true, message: "Disponib!" }
    end
  end

  # GET /users/lookup?q=xxx (JSON, authenticated)
  # Live search user by cashtag, email, or phone for withdrawals/transfers
  def lookup
    q = params[:q].to_s.strip.downcase.delete_prefix("$")

    if q.blank? || q.length < 2
      render json: { found: false, message: "Tape omwen 2 karaktè." }
      return
    end

    others = User.where.not(id: current_user.id)
    user = nil

    # 1. Exact cashtag match first
    user = others.where("LOWER(cashtag) = ?", q).first

    # 2. Partial cashtag match (starts with)
    user ||= others.where("LOWER(cashtag) LIKE ?", "#{q}%").first

    # 3. Email match (starts with, before @)
    user ||= others.where("LOWER(email) LIKE ?", "#{q}%").first

    # 4. Phone number match
    user ||= others.where(phone_number: q).first if q.match?(/\A509\d{8}\z/)

    unless user
      render json: { found: false, message: "Pa jwenn itilizatè sa a." }
      return
    end

    # Find their active MonCash payment method
    moncash_pm = user.payment_methods.where(active: true, category: "mobile_wallet", provider: "moncash").order(created_at: :desc).first
    phone = moncash_pm&.account_number || user.phone_number

    avatar_url = user.avatar.attached? ? url_for(user.avatar) : nil

    render json: {
      found: true,
      user_id: user.id,
      display_name: user.display_name,
      cashtag: user.cashtag,
      moncash_phone: phone.presence,
      has_moncash: phone.present?,
      avatar_url: avatar_url
    }
  end

  # GET /setup_cashtag — onboarding for existing users without cashtag
  def setup_cashtag
    redirect_to root_path if current_user.cashtag.present?
  end

  # POST /setup_cashtag
  def save_cashtag
    current_user.assign_attributes(
      cashtag: params[:cashtag],
      phone_number: params[:phone_number].presence
    )

    if current_user.save
      redirect_to root_path, notice: "Zellustag $#{current_user.cashtag} enstale!"
    else
      render :setup_cashtag, status: :unprocessable_entity
    end
  end
end
