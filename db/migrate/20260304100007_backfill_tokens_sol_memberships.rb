class BackfillTokensSolMemberships < ActiveRecord::Migration[8.0]
  def up
    SolMembership.where(token: nil).find_each do |sm|
      sm.update_column(:token, SecureRandom.urlsafe_base64(12))
    end

    change_column_null :sol_memberships, :token, false
  end

  def down
    change_column_null :sol_memberships, :token, true
  end
end
