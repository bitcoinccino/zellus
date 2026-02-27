class SolCirclesController < ApplicationController
  before_action :authenticate_user!

  # List all circles the user has joined (Pijon/Malfini Dashboard)
  def index
    @circles = current_user.sol_circles.order(created_at: :desc)
  end

  # Show the rotation, payout holder, and invite link for a specific circle
  def show
    @circle = current_user.sol_circles.find_by!(token: params[:token])
    @members = @circle.sol_memberships.order(:position)
    @current_round = @circle.sol_rounds.collecting.last || @circle.sol_rounds.last
  end

  # The flying bird animation page after joining
  def success
    @circle = current_user.sol_circles.find_by!(token: params[:token])
  end

  # Form to create a new PrioSol
  def new
    @circle = SolCircle.new(asset: "htg", target_members: 5, creator_fee_percent: 0)
  end

  # Save circle and auto-enroll creator as position 1
  def create
    @circle = current_user.sol_circles_created.build(circle_params)
    @circle.status = :pending

    if @circle.save
      @circle.sol_memberships.create!(user: current_user, position: 1)
      SolMailer.with(circle: @circle).circle_created.deliver_later
      redirect_to sol_circle_path(@circle.token), notice: "PrioSol kreye avèk siksè!"
    else
      render :new, status: :unprocessable_entity
    end
  end

  private

  def circle_params
    params.require(:sol_circle).permit(:name, :asset, :amount, :frequency, :target_members, :creator_fee_percent, :category)
  end
end
