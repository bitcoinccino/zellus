# Issues + verifies email one-time codes for the OTP auth flow.
#
# Used by OtpAuthController for both sign-in and sign-up — the User row may
# not exist yet when a code is requested (signup), so this layer operates
# purely on the email string.
class OtpService
  REQUEST_COOLDOWN = 60.seconds

  Result = Struct.new(:success?, :error, :email_otp, :retry_after_seconds, keyword_init: true)

  class << self
    # Generates a new code and mails it. Returns a Result.
    #
    # error symbols:
    #   :rate_limited   — a fresh code was issued within the cooldown window
    #   :invalid_email  — email format invalid
    def request_for!(email, ip: nil, purpose: "login")
      normalized = normalize(email)
      return Result.new(success?: false, error: :invalid_email) if normalized.blank?

      if (existing = EmailOtp.latest_active_for(normalized))
        age = Time.current - existing.created_at
        if age < REQUEST_COOLDOWN
          return Result.new(
            success?: false,
            error: :rate_limited,
            email_otp: existing,
            retry_after_seconds: (REQUEST_COOLDOWN - age).ceil
          )
        end
      end

      code = EmailOtp.generate_for!(normalized, purpose: purpose, ip: ip)
      OtpMailer.with(email: normalized, code: code).code_email.deliver_later

      Result.new(success?: true, email_otp: EmailOtp.latest_active_for(normalized))
    end

    # Verifies the submitted code against the latest active EmailOtp for the
    # email. Returns a Result. On success, callers should look up or create
    # the user themselves — this service does NOT touch the User table.
    #
    # error symbols:
    #   :no_code         — nothing to verify (expired/consumed/never sent)
    #   :exhausted       — too many wrong attempts
    #   :invalid_code    — wrong digits
    def verify!(email, submitted_code)
      normalized = normalize(email)
      return Result.new(success?: false, error: :no_code) if normalized.blank?

      otp = EmailOtp.latest_active_for(normalized)
      return Result.new(success?: false, error: :no_code) if otp.nil?

      if otp.exhausted?
        return Result.new(success?: false, error: :exhausted, email_otp: otp)
      end

      if otp.verify!(submitted_code)
        Result.new(success?: true, email_otp: otp)
      elsif otp.reload.exhausted?
        Result.new(success?: false, error: :exhausted, email_otp: otp)
      else
        Result.new(success?: false, error: :invalid_code, email_otp: otp)
      end
    end

    private

    def normalize(email)
      return nil if email.blank?
      stripped = email.to_s.strip.downcase
      stripped.match?(User::EMAIL_FORMAT) ? stripped : nil
    end
  end
end
