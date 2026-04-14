class NotificationsController < ApplicationController
  before_action :authenticate_user!

  PER_PAGE = 15

  def index
    scope = current_user.notifications
              .includes(:notifiable, actor: { avatar_attachment: :blob })
              .recent_first

    # Cursor-based pagination: load items older than the cursor
    if params[:cursor].present?
      cursor_time = Time.zone.parse(params[:cursor]) rescue nil
      scope = scope.where("notifications.created_at < ?", cursor_time) if cursor_time
    end

    @notifications = scope.limit(PER_PAGE + 1).to_a
    @has_more = @notifications.size > PER_PAGE
    @notifications = @notifications.first(PER_PAGE)
    @next_cursor = @notifications.last&.created_at&.iso8601(6) if @has_more

    respond_to do |format|
      format.html
      format.json do
        html = @notifications.map { |n|
          render_to_string(partial: "notifications/activity_card", locals: { notif: n })
        }.join

        render json: { html: html, has_more: @has_more, next_cursor: @next_cursor }
      end
    end
  end

  def show
    @notification = find_notification(params[:id])
    @notification.mark_read!
    @actor = @notification.actor
    @notifiable = @notification.notifiable
  end

  def mark_read
    notification = find_notification(params[:id])
    notification.mark_read!
    redirect_to notification_path(notification)
  end

  def mark_all_read
    current_user.notifications.unread.update_all(read_at: Time.current)

    respond_to do |format|
      format.json { render json: { ok: true, unread_count: 0 } }
      format.html { redirect_back fallback_location: notifications_path }
    end
  end

  def send_thanks
    notif = find_notification(params[:id])

    head :unprocessable_entity and return unless notif.notification_type == "transfer_received"
    head :unprocessable_entity and return unless notif.actor.present?

    transfer = notif.notifiable
    already_thanked = Notification.exists?(
      notification_type: "thanks_received",
      user_id: notif.actor_id,
      actor_id: current_user.id,
      notifiable: transfer
    )
    head :unprocessable_entity and return if already_thanked

    NotificationService.thanks_received(transfer: transfer, thanker: current_user, recipient: notif.actor)

    respond_to do |format|
      format.json { render json: { ok: true } }
      format.html { redirect_to notification_path(notif) }
    end
  end

  # Lightweight JSON poll for sound fallback when WebSocket is disconnected.
  # Returns the latest unread sound-eligible notification so the client
  # can play the chime even if the real-time broadcast was missed.
  SOUND_TYPES = %w[transfer_received].freeze

  def poll
    latest_sound = current_user.notifications
                     .where(notification_type: SOUND_TYPES)
                     .where(read_at: nil)
                     .order(created_at: :desc)
                     .limit(1)
                     .pick(:token, :created_at)

    unread_count = current_user.notifications.unread.count

    render json: {
      unread_count: unread_count,
      latest_sound_id: latest_sound&.first,
      latest_sound_at: latest_sound&.last&.iso8601
    }
  end

  private

  def find_notification(param_id)
    current_user.notifications
      .includes(:actor, :notifiable)
      .find_by!(token: param_id)
  end
end
