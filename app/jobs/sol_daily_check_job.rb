class SolDailyCheckJob < ApplicationJob
  queue_as :default

  def perform
    # Find all active circles where today matches the start_date's day of the week
    # e.g., If it started on a Sunday and is 'weekly', trigger every Sunday.
    SolCircle.active.find_each do |circle|
      if circle.due_today?
        SolOrchestrator.new(circle).process_current_round!
      end
    end
  end
end
