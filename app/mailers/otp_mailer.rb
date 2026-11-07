class OtpMailer < ApplicationMailer
  COPY = {
    "login"        => { heading: "Kòd Konekte Ou",
                        subject: "Kòd Konekte Zèllus",
                        intro: "Antre kòd sa a nan paj konektesyon Zèllus pou kontinye." },
    "pin_reset"    => { heading: "Kòd pou Reyinisyalize PIN Ou",
                        subject: "Kòd pou Reyinisyalize PIN Zèllus",
                        intro: "Yon moun mande pou reyinisyalize PIN kont ou a. Antre kòd sa a pou kontinye." },
    "email_change" => { heading: "Kòd pou Chanje Imèl Ou",
                        subject: "Kòd pou Chanje Imèl Zèllus",
                        intro: "Antre kòd sa a pou konfime nouvo imèl kont Zèllus ou a." }
  }.freeze

  def code_email
    @code  = params[:code]
    @email = params[:email]
    @ttl_minutes = (EmailOtp::CODE_TTL / 60).to_i
    @copy = COPY.fetch(params[:purpose].to_s, COPY["login"])

    mail(
      to:      @email,
      subject: "#{@copy[:subject]}: #{@code}"
    )
  end
end
