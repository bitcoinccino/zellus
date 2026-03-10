class NotificationChannel < ApplicationCable::Channel
  def subscribed
    if current_user
      stream_for current_user
      logger.info "[NotificationChannel] Streaming for user #{current_user.id} (#{current_user.class.name}##{current_user.id})"
    else
      logger.error "[NotificationChannel] current_user is NIL — cannot stream"
      reject
    end
  end
end
