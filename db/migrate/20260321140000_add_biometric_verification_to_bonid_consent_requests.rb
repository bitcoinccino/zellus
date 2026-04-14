class AddBiometricVerificationToBonidConsentRequests < ActiveRecord::Migration[7.1]
  def change
    add_column :bonid_consent_requests, :biometric_verification, :jsonb
  end
end
