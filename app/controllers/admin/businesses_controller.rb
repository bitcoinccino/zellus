class Admin::BusinessesController < Admin::BaseController
  def applicants
  end

  def analytics
  end

  def activity
  end

  def toggle_agent
    business = Business.find(params[:id])
    if business.is_agent?
      business.deactivate_agent!
      redirect_to admin_businesses_applicants_path, notice: "#{business.name} dezaktive kòm ajan."
    else
      business.activate_agent!
      redirect_to admin_businesses_applicants_path, notice: "#{business.name} aktive kòm ajan Zèllus!"
    end
  end
end
