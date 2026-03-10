class ApplicationMailer < ActionMailer::Base
  default from: -> { ENV["MAILER_FROM"].presence || "Zèllus <no-reply@priotelus.com>" }
  layout "mailer"
end
