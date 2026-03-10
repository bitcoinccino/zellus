class BackfillTokensBankWithdrawalsAndProducts < ActiveRecord::Migration[8.0]
  def up
    BankWithdrawal.where(token: nil).find_each do |bw|
      bw.update_column(:token, SecureRandom.urlsafe_base64(12))
    end

    Product.where(token: nil).find_each do |p|
      p.update_column(:token, SecureRandom.urlsafe_base64(12))
    end

    change_column_null :bank_withdrawals, :token, false
    change_column_null :products, :token, false
  end

  def down
    change_column_null :bank_withdrawals, :token, true
    change_column_null :products, :token, true
  end
end
