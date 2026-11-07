class SecurityMailer < ApplicationMailer
  def alert
    @title = params[:title]
    @body  = params[:body]

    mail(to: params[:email], subject: "Zèllus Sekirite: #{@title}")
  end
end
