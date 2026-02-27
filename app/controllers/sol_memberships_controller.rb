# app/controllers/sol_memberships_controller.rb
class SolMembershipsController < ApplicationController # Corrected inheritance
  before_action :authenticate_user!
  before_action :set_circle

  # GET /sol_circles/:token/join
  def join
    # If already a member, go straight to the dashboard
    if @circle.users.include?(current_user)
      redirect_to sol_circle_path(@circle.token), notice: "Ou deja nan Sol sa a!"
    end
  end

  # POST /sol_circles/:token/confirm_join
  def confirm_join
    # 1. Validation: Prevent joining if Sol is already active or finished
    unless @circle.pending?
      return redirect_to root_path, alert: "Sol sa a deja kòmanse oswa li fini."
    end

    # 2. Logic: Assign the next seat in the rotation (1, 2, 3...)
    next_position = @circle.sol_memberships.count + 1

    @membership = @circle.sol_memberships.new(
      user: current_user, 
      position: next_position
    )

    if @membership.save
      # Notify all existing members about the new joiner
      @circle.sol_memberships.where.not(user: current_user).find_each do |m|
        SolMailer.with(circle: @circle, new_member: current_user, user: m.user).member_joined.deliver_later
      end

      # 3. Automation: Check if we have enough people to start
      check_and_activate_circle

      # 4. Success: Send them to the flying bird animation page
      redirect_to success_sol_circle_path(@circle.token)
    else
      redirect_to join_sol_circle_path(@circle.token), alert: "Erè: Nou pa ka ajoute'w nan Sol la kounye a."
    end
  end

  # GET /sol_circles/:token/success
  def success
    # This renders the view with the flying bird animation we just built
  end

  private

  def set_circle
    # We use param: :token in the routes to find circles safely
    @circle = SolCircle.find_by!(token: params[:token])
  end

  def check_and_activate_circle
    if @circle.full?
      @circle.update!(status: :active, start_date: Time.current)

      # Notify all members that the Sol is now active
      @circle.sol_memberships.find_each do |m|
        SolMailer.with(circle: @circle, user: m.user).circle_activated.deliver_later
      end

      # Kick off round 1 immediately
      SolOrchestrator.new(@circle).process_current_round!
    end
  end
end
