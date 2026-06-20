class Admin::UsersController < Admin::BaseController
  def analytics
  end

  # Searchable user list (email / cashtag) with PIN + lockout status.
  def index
    @query = params[:q].to_s.strip
    scope  = User.order(created_at: :desc)

    if @query.present?
      like  = "%#{@query.downcase}%"
      scope = scope.where("LOWER(email) LIKE :q OR LOWER(cashtag) LIKE :q", q: like)
    end

    @users = scope.limit(50)
  end

  # Support escape hatch: clear a user's transfer PIN and lockout so they're
  # prompted to create a fresh PIN on their next login (the /login/pin gate).
  def clear_pin
    user = User.find(params[:id])
    user.transfer_pin = nil
    user.save!
    user.reset_pin_attempts!
    redirect_to admin_users_path(q: params[:q]),
                notice: "PIN #{user.email} reyinisyalize. L ap kreye yon nouvo PIN nan pwochen koneksyon."
  end
end
