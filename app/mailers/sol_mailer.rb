class SolMailer < ApplicationMailer
  # 1. Circle created — sent to creator
  def circle_created
    @circle = params[:circle]
    @user = @circle.user
    mail(to: @user.email, subject: "PrioSol kreye: #{@circle.name}")
  end

  # 2. New member joined — sent to all existing members
  def member_joined
    @circle = params[:circle]
    @new_member = params[:new_member]
    @user = params[:user]
    mail(to: @user.email, subject: "Nouvo manm nan #{@circle.name}")
  end

  # 3. Circle activated — sent to all members when circle is full and starts
  def circle_activated
    @circle = params[:circle]
    @user = params[:user]
    mail(to: @user.email, subject: "#{@circle.name} kòmanse! Wonn 1 lanse")
  end

  # 4. New round started — sent to all contributing members (not the recipient)
  def round_started
    @circle = params[:circle]
    @round = params[:round]
    @user = params[:user]
    @payment_request = params[:payment_request]
    mail(to: @user.email, subject: "Sol #{@circle.name}: Wonn #{@round.round_number} — Peye kounye a")
  end

  # 5. Payment reminder — sent to unpaid members before grace period ends
  def payment_reminder
    @circle = params[:circle]
    @round = params[:round]
    @user = params[:user]
    @hours_left = params[:hours_left]
    mail(to: @user.email, subject: "Rapèl: Ou gen #{@hours_left}è pou peye Sol #{@circle.name}")
  end

  # 6. Payout received — sent to the round recipient
  def payout_received
    @circle = params[:circle]
    @round = params[:round]
    @user = params[:user]
    @amount = params[:amount]
    mail(to: @user.email, subject: "Ou resevwa peman Sol #{@circle.name}!")
  end

  # 7. Missed payment warning — sent to delinquent members
  def missed_payment
    @circle = params[:circle]
    @user = params[:user]
    mail(to: @user.email, subject: "Avètisman: Peman manke nan Sol #{@circle.name}")
  end

  # 8. Member removed/defaulted — sent to the removed member
  def member_defaulted
    @circle = params[:circle]
    @user = params[:user]
    mail(to: @user.email, subject: "Ou retire nan Sol #{@circle.name}")
  end

  # 9. Circle completed — sent to all active members
  def circle_completed
    @circle = params[:circle]
    @user = params[:user]
    mail(to: @user.email, subject: "Felisitasyon! Sol #{@circle.name} fini avèk siksè")
  end
end
