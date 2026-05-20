class OtpMailer < ApplicationMailer
  def code_email
    @code  = params[:code]
    @email = params[:email]
    @ttl_minutes = (EmailOtp::CODE_TTL / 60).to_i

    mail(
      to:      @email,
      subject: "Kòd Konekte Zèllus: #{@code}"
    )
  end
end
