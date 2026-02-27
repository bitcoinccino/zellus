class PaymentRequestsController < ApplicationController
  before_action :authenticate_user!, except: [:public_show]
  before_action :set_payment_request, only: [:show, :update, :destroy]

  def index
    @payment_requests = current_user.payment_requests.recent_first
  end

  def new
    @payment_request = current_user.payment_requests.new(asset: :htg, status: :active)
  end

  def create
    @payment_request = current_user.payment_requests.new(payment_request_params)
    @payment_request.status = :active
    @payment_request.expires_at = 48.hours.from_now.change(sec: 0)

    if @payment_request.save
      PaymentRequestMailer.with(payment_request_id: @payment_request.id).request_created.deliver_later
      redirect_to payment_request_path(@payment_request), notice: "Demann peman kreye."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def show
    @payment_request.mark_expired_if_needed!
    @share_url = public_payment_request_url(@payment_request.token)
  end

  def update
    if params[:mark_paid].present?
      @payment_request.update!(status: :paid)
      PaymentRequestMailer.with(payment_request_id: @payment_request.id).request_paid.deliver_later
      redirect_to payment_request_path(@payment_request), notice: "Demann peman make kòm peye."
    elsif params[:cancel].present?
      @payment_request.update!(status: :canceled)
      PaymentRequestMailer.with(payment_request_id: @payment_request.id).request_canceled.deliver_later
      redirect_to payment_request_path(@payment_request), notice: "Demann peman anile."
    else
      redirect_to payment_request_path(@payment_request), alert: "Pa gen aksyon chwazi."
    end
  end

  def destroy
    @payment_request.destroy!
    redirect_to payment_requests_path, notice: "Demann peman efase."
  end

  def public_show
    @payment_request = PaymentRequest.find_by!(token: params[:token])
    @payment_request.mark_expired_if_needed!
    @share_url = public_payment_request_url(@payment_request.token)
  end

  private

  def set_payment_request
    @payment_request = current_user.payment_requests.find(params[:id])
  end

  def payment_request_params
    params.require(:payment_request).permit(:asset, :amount, :payer_name, :note)
  end

  def default_request_expiration_time
    48.hours.from_now.change(sec: 0)
  end

end
