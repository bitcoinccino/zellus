class ApplicationMailer < ActionMailer::Base
  default from: -> { ENV["MAILER_FROM"].presence || AppBrand::MAILER_FROM }
  layout "mailer"

  before_action :attach_logo

  private

  def attach_logo
    logo_path = Rails.root.join("app", "assets", "images", "zellus_square.png")
    if File.exist?(logo_path)
      attachments.inline["zellus_logo.png"] = File.read(logo_path)
    end
  end
end
