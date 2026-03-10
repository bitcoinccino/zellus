class NotificationsController < ApplicationController
  before_action :authenticate_user!

  def index
    @notifications = current_user.notifications.recent_first.limit(50)
  end

  def mark_read
    notification = current_user.notifications.find(params[:id])
    notification.mark_read!
    redirect_to notification.url || wallet_path
  end

  def mark_all_read
    current_user.notifications.unread.update_all(read_at: Time.current)
    redirect_back fallback_location: notifications_path
  end
end
