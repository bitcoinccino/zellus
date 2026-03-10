module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    def connect
      self.current_user = find_verified_user
      logger.info "[ActionCable] User #{current_user.id} connected" if current_user
    end

    private

    def find_verified_user
      if (user = env["warden"].user)
        user
      else
        reject_unauthorized_connection
      end
    end
  end
end
