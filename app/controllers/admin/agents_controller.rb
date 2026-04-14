class Admin::AgentsController < Admin::BaseController
  def applicants
    @pending  = Business.includes(user: { avatar_attachment: :blob }).agent_pending.order(agent_applied_at: :desc)
    @approved = Business.includes(user: { avatar_attachment: :blob }).where(is_agent: true, agent_status: :approved).order(agent_activated_at: :desc)
    @rejected = Business.includes(user: { avatar_attachment: :blob }).where(agent_status: :rejected).order(updated_at: :desc)
    @suspended = Business.includes(user: { avatar_attachment: :blob }).where(agent_status: :suspended).order(updated_at: :desc)
  end

  def show
    @business = Business.includes(:user).find(params[:id])
    @agent_transactions = @business.agent_transactions.includes(:customer).order(created_at: :desc).limit(25) if @business.is_agent?
  end

  def approve
    business = Business.find(params[:id])
    unless business.agent_application_pending?
      redirect_to admin_agents_applicants_path, alert: "Aplikasyon sa a pa an atant."
      return
    end

    business.approve_agent!

    begin
      NotificationService.agent_application_approved(business)
    rescue => e
      Rails.logger.error "Agent approval notification failed: #{e.message}"
    end

    redirect_to admin_agents_applicants_path, notice: "#{business.name} apwouve kòm ajan Zèllus!"
  end

  def reject
    business = Business.find(params[:id])
    unless business.agent_application_pending?
      redirect_to admin_agents_applicants_path, alert: "Aplikasyon sa a pa an atant."
      return
    end

    reason = params[:reason].to_s.strip.presence || "Pa kalifye pou kounye a"
    business.reject_agent!(reason: reason)

    begin
      NotificationService.agent_application_rejected(business, reason)
    rescue => e
      Rails.logger.error "Agent rejection notification failed: #{e.message}"
    end

    redirect_to admin_agents_applicants_path, notice: "Aplikasyon #{business.name} rejte."
  end

  def suspend
    business = Business.find(params[:id])
    unless business.is_agent?
      redirect_to admin_agents_applicants_path, alert: "Biznis sa a pa yon ajan."
      return
    end

    reason = params[:reason].to_s.strip.presence || "Vyolasyon règ platfòm"
    business.deactivate_agent!

    begin
      NotificationService.agent_suspended(business, reason)
    rescue => e
      Rails.logger.error "Agent suspension notification failed: #{e.message}"
    end

    redirect_to admin_agents_applicants_path, notice: "#{business.name} sispann kòm ajan."
  end

  def reactivate
    business = Business.find(params[:id])
    unless business.agent_status == "suspended"
      redirect_to admin_agents_show_path(business), alert: "Biznis sa a pa sispann."
      return
    end

    business.reactivate_agent!

    begin
      NotificationService.agent_reactivated(business)
    rescue => e
      Rails.logger.error "Agent reactivation notification failed: #{e.message}"
    end

    redirect_to admin_agents_show_path(business), notice: "#{business.name} reaktive kòm ajan!"
  end

  def analytics
    @total_agents = Business.where(is_agent: true).count
    @pending_count = Business.agent_pending.count
    @rejected_count = Business.where(agent_status: "rejected").count

    # Transaction stats
    @total_transactions = AgentTransaction.completed.count
    @total_volume_htg = AgentTransaction.completed.sum(:amount)
    @total_commission = AgentTransaction.completed.sum(:commission_amount)
    @cash_in_count = AgentTransaction.completed.cash_in.count
    @cash_in_volume = AgentTransaction.completed.cash_in.sum(:amount)

    # Today stats
    @today_transactions = AgentTransaction.completed.today.count
    @today_volume = AgentTransaction.completed.today.sum(:amount)
    @today_commission = AgentTransaction.completed.today.sum(:commission_amount)

    # Top agents by volume
    @top_agents = Business.agents
      .joins(:agent_transactions)
      .where(agent_transactions: { status: "completed" })
      .select("businesses.*, SUM(agent_transactions.amount) AS total_volume, COUNT(agent_transactions.id) AS tx_count, SUM(agent_transactions.commission_amount) AS earned")
      .group("businesses.id")
      .order("total_volume DESC")
      .limit(10)
      .includes(:user)
  end

  def activity
    @transactions = AgentTransaction.includes(business: :user, customer: {})
      .order(created_at: :desc)

    # Filters
    if params[:type].present?
      @transactions = @transactions.where(transaction_type: params[:type])
    end
    if params[:status].present?
      @transactions = @transactions.where(status: params[:status])
    end
    if params[:q].present?
      q = params[:q].strip
      if q.start_with?("$")
        cashtag = q.delete("$")
        user_ids = User.where("LOWER(cashtag) LIKE ?", "%#{cashtag.downcase}%").pluck(:id)
        biz_ids = Business.where(user_id: user_ids).pluck(:id)
        @transactions = @transactions.where(business_id: biz_ids).or(@transactions.where(customer_id: user_ids))
      else
        @transactions = @transactions.where("confirmation_code ILIKE ?", "%#{q}%")
      end
    end
    if params[:date].present?
      date = Date.parse(params[:date]) rescue nil
      @transactions = @transactions.where(created_at: date.all_day) if date
    end

    # Pagination
    @per_page = 25
    @current_page = (params[:page] || 1).to_i
    @total_count = @transactions.count
    @total_pages = (@total_count.to_f / @per_page).ceil
    @current_page = @total_pages if @current_page > @total_pages && @total_pages > 0
    @transactions = @transactions.offset((@current_page - 1) * @per_page).limit(@per_page)
  end
end
