class ApplicationMailer < ActionMailer::Base
  default from: -> { ENV["MAILER_FROM"].presence || "Priotelus <no-reply@priotelus.com>" }
  layout "mailer"
end
