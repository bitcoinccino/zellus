module TransactionMailerHelper
  def amount_line
    @amount_line
  end

  def payment_method_label
    @payment_method_label
  end

  def source_label
    @source_label
  end

  def destination_label
    @destination_label
  end

  def verification_links
    @verification_links || []
  end

  def network_label
    @network_label
  end

  def customer_failure_message
    @customer_failure_message
  end
end
