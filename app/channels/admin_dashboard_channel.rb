class AdminDashboardChannel < ApplicationCable::Channel
  def subscribed
    stream_from "admin_dashboard"
  end

  def unsubscribed
    # cleanup
  end
end
