class PagesController < ApplicationController
  skip_before_action :require_cashtag!, raise: false

  def priosol; end
  def priobousad; end
  def prionet; end
  def zellus; end
  def ajan; end
  def resevwa; end
  def apwopo; end
  def faq; end

  def annye
    scope = Business.agents.where(status: "active").with_attached_logo

    if params[:q].present?
      scope = scope.where("name ILIKE ?", "%#{params[:q]}%")
    end

    scope = scope.where(department: params[:department]) if params[:department].present?
    scope = scope.where(commune: params[:commune])       if params[:commune].present?

    @businesses = scope.order(:name)

    if params[:open_now] == "1"
      @businesses = @businesses.select(&:open_now?)
    end
  end
end
