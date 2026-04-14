class PaymentMethodsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_payment_method, only: [:update, :destroy, :set_default]

  def index
    load_payment_methods
    @payment_method = build_new_payment_method
  end

  def create
    @payment_method = current_user.payment_methods.new(payment_method_params)

    if @payment_method.save
      redirect_to payment_methods_path, notice: "Metod peman ajoute!"
    else
      load_payment_methods
      render :index, status: :unprocessable_entity
    end
  end

  def update
    if @payment_method.update(payment_method_params)
      redirect_to payment_methods_path, notice: "Metod peman modifye!"
    else
      error_message = @payment_method.errors.full_messages.to_sentence
      load_payment_methods
      @payment_method = build_new_payment_method
      flash.now[:alert] = error_message
      render :index, status: :unprocessable_entity
    end
  end

  def set_default
    @payment_method.make_default!
    redirect_to payment_methods_path, notice: "#{@payment_method.display_label} se metod prensipal ou kounye a!"
  end

  def destroy
    @payment_method.destroy!
    redirect_to payment_methods_path, notice: "Metod peman retire!"
  end

  private

  def set_payment_method
    @payment_method = current_user.payment_methods.find_by!(token: params[:token])
  end

  def load_payment_methods
    @payment_methods = current_user.payment_methods.order(is_default: :desc, active: :desc, created_at: :desc)
    @mobile_wallet_methods = @payment_methods.select(&:mobile_wallet?)
    @crypto_wallet_methods = @payment_methods.select(&:crypto_wallet?)
    @bank_account_methods  = @payment_methods.select(&:bank_account?)
  end

  def build_new_payment_method
    current_user.payment_methods.new(category: :mobile_wallet, provider: :moncash, active: true)
  end

  def payment_method_params
    params.require(:payment_method).permit(:category, :provider, :network, :asset, :account_number, :wallet_address, :label, :active, :bank_account_number, :account_holder_name)
  end
end
