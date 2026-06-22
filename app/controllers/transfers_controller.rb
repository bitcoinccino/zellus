class TransfersController < ApplicationController
  include ActionView::Helpers::NumberHelper
  include BonidRecheckable
  before_action :authenticate_user!, except: [ :claim, :claim_confirm ]
  before_action :recheck_bonid!, only: [ :confirm ]

  # ── GET /transfers/new ──
  def new
    @transfer = current_user.transfers.new
    @daily_remaining = current_user.daily_transfer_remaining
    @business = current_user.business
    load_saved_methods
    load_rates
  end

  # ── POST /transfers/set_pin — Set transfer PIN ──
  def set_pin
    pin         = params[:transfer_pin].to_s.strip
    confirm_pin = params[:transfer_pin_confirmation].to_s.strip

    unless pin.match?(/\A\d{4}\z/)
      flash[:alert] = "PIN dwe 4 chif."
      redirect_back fallback_location: new_transfer_path
      return
    end

    if pin != confirm_pin
      flash[:alert] = "De PIN yo pa menm. Tanpri verifye epi eseye ankò."
      redirect_back fallback_location: new_transfer_path
      return
    end

    current_user.transfer_pin = pin
    current_user.save!
    flash[:notice] = "PIN transfè ou enstale avèk siksè!"
    redirect_back fallback_location: new_transfer_path
  end

  # ── POST /transfers ──
  def create
    @daily_remaining = current_user.daily_transfer_remaining
    load_saved_methods
    load_rates

    asset_type = params[:asset].to_s
    asset_type = "htg" unless %w[htg usd].include?(asset_type)

    @transfer = current_user.transfers.new(transfer_params)
    @transfer.asset = asset_type

    # Resolve biz_slug → business_id (prevents IDOR via raw integer IDs)
    if params[:biz_slug].present?
      biz = Business.find_by(slug: params[:biz_slug])
      @transfer.business_id = biz.id if biz
    end

    # Store tip_amount if provided (from tippable pay pages)
    if params[:tip_amount].present?
      @transfer.tip_amount = params[:tip_amount].to_f
    end

    # Resolve receiver from saved method or manual input
    resolve_receiver(@transfer, asset_type)

    # For crypto transfers, calculate crypto amount from HTG
    if @transfer.crypto_transfer?
      rate = exchange_rate_for(asset_type)
      if rate && rate > 0 && @transfer.amount.to_f > 0
        @transfer.exchange_rate = rate
        precision = %w[wbtc eth tslax nvdax aaplx coinx googlx].include?(asset_type) ? 8 : 6
        @transfer.crypto_amount = (@transfer.amount.to_f / rate).round(precision)
      end
    end

    # PIN not required here — it's checked on the show page before confirming
    # But PIN must be set
    unless current_user.transfer_pin_set?
      flash.now[:alert] = "Ou dwe kreye yon PIN transfè anvan ou voye lajan."
      render :new, status: :unprocessable_entity
      return
    end

    # Per-transaction limits
    if send_limit_error(@transfer.amount).present?
      flash.now[:alert] = send_limit_error(@transfer.amount)
      render :new, status: :unprocessable_entity
      return
    end

    # Daily limit check
    if daily_limit_error(@transfer.amount).present?
      flash.now[:alert] = daily_limit_error(@transfer.amount)
      render :new, status: :unprocessable_entity
      return
    end

    unless @transfer.save
      render :new, status: :unprocessable_entity
      return
    end

    # ── BonID Per-Transaction Consent (BEFORE review/PIN step) ──
    # If the amount exceeds the threshold, request consent from BonID first.
    # The user must approve on their BonID portal before they can review & confirm.
    if BonIdService.consent_required?(@transfer)
      unless current_user.bonid_verified?
        @transfer.update!(status: :failed, failure_reason: "BonID pa verifye")
        redirect_to transfer_path(@transfer),
          alert: "Pou pwoteje kont ou, montan sa a mande yon verifikasyon BonID."
        return
      end

      consent_result = BonIdService.request_consent(@transfer)

      if consent_result[:success]
        @transfer.update!(status: :awaiting_consent)

        BonidConsentRequest.create!(
          user: current_user,
          transfer: @transfer,
          consent_token: consent_result[:consent_token],
          bonid: current_user.bonid,
          reference_id: "ZEL-transfer-#{@transfer.token}",
          amount: @transfer.amount,
          transaction_type: "p2p_transfer",
          expires_at: consent_result[:expires_at]
        )

        redirect_to transfer_path(@transfer),
          notice: "Tanpri apwouve transfè sa a nan BonID ou. Tcheke imèl ou pou kòd OTP."
        return
      else
        @transfer.update!(status: :failed, failure_reason: "BonID consent endiponib")
        redirect_to transfer_path(@transfer),
          alert: "Nou pa t kapab kontakte BonID. Tanpri eseye ankò."
        return
      end
    end

    # Redirect to show page for PIN confirmation before payment
    redirect_to transfer_path(@transfer)
  end

  # ── GET /transfers/:id ──
  def show
    @transfer = find_transfer_for_current_user(params[:id] || params[:token])
    @claim_url = claim_transfer_url(@transfer.token)
    @needs_pin = @transfer.pending? && current_user.transfer_pin_set?
    @receiver_user = find_receiver_user_for(@transfer)
    @consent = @transfer.bonid_consent_request

    # Viewing the transaction marks its notification(s) read, so the unread
    # bell total stays in sync whether the user arrives from the feed or
    # opens the transfer directly. Runs before the view renders, so the
    # unread_notification_count helper picks up the decremented count.
    current_user.notifications.unread
                .where(notifiable: @transfer)
                .update_all(read_at: Time.current)
  end

  # ── POST /transfers/:token/confirm — PIN verification + initiate payment ──
  def confirm
    @transfer = find_transfer_for_current_user(params[:id] || params[:token])

    unless @transfer.pending?
      redirect_to transfer_path(@transfer), alert: "Transfè sa a deja konfime."
      return
    end

    # Verify PIN
    unless current_user.verify_transfer_pin(params[:transfer_pin])
      flash[:alert] = "PIN pa kòrèk. Tanpri eseye ankò."
      redirect_to transfer_path(@transfer)
      return
    end

    # BonID consent was already handled in create — check it's approved
    @consent_already_approved = @transfer.bonid_consent_request&.approved?

    # ── Bank transfer (HTG → Unibank, wallet-funded, admin-processed) ──
    if @transfer.bank_transfer?
      wallet = current_user.ensure_wallet!

      unless wallet.sufficient_balance?(@transfer.amount)
        redirect_to transfer_path(@transfer),
                    alert: "Balans pòtfèy pa sifi. Ou bezwen #{@transfer.amount.to_i} HTG men ou gen #{wallet.htg_balance.to_i} HTG."
        return
      end

      begin
        entry = WalletService.new(wallet).transfer_out!(
          amount: @transfer.amount,
          fee: @transfer.fee,
          transfer: @transfer
        )

        # ── BonID Per-Transaction Consent Check (Bank) ──
        if BonIdService.consent_required?(@transfer) && !@consent_already_approved
          unless current_user.bonid_verified?
            WalletService.new(wallet).refund!(
              amount: @transfer.amount,
              asset: "htg",
              reference: @transfer,
              reason: "BonID obligatwa pou transfè >= #{BonIdService::CONSENT_THRESHOLD.to_i} HTG"
            )
            @transfer.update!(status: :failed, failure_reason: "BonID pa verifye")
            redirect_to transfer_path(@transfer),
              alert: "Pou pwoteje kont ou, montan sa a mande yon verifikasyon BonID."
            return
          end

          consent_result = BonIdService.request_consent(@transfer)

          if consent_result[:success]
            @transfer.update!(
              status: :awaiting_consent,
              funded_at: Time.current,
              funding_source: "wallet"
            )

            BonidConsentRequest.create!(
              user: current_user,
              transfer: @transfer,
              consent_token: consent_result[:consent_token],
              bonid: current_user.bonid,
              reference_id: "ZEL-transfer-#{@transfer.token}",
              amount: @transfer.amount,
              transaction_type: "p2p_transfer",
              expires_at: consent_result[:expires_at]
            )

            redirect_to transfer_path(@transfer),
              notice: "Tanpri apwouve transfè sa a nan BonID ou. Tcheke imèl ou pou kòd OTP."
            return
          else
            WalletService.new(wallet).refund!(
              amount: @transfer.amount,
              asset: "htg",
              reference: @transfer,
              reason: "BonID consent endiponib — ranbouse #{@transfer.amount.to_i} HTG"
            )
            @transfer.update!(status: :failed, failure_reason: "BonID consent endiponib")
            redirect_to transfer_path(@transfer),
              alert: "Pou pwoteje kont ou, montan sa a mande yon verifikasyon BonID."
            return
          end
        end

        @transfer.update!(
          status: :funded,
          funded_at: Time.current,
          funding_source: "wallet"
        )

        # Create a BankWithdrawal for admin processing
        BankWithdrawal.create!(
          user: current_user,
          wallet: wallet,
          wallet_ledger_entry: entry,
          amount: @transfer.amount,
          bank_name: @transfer.receiver_bank_name || "UNIBANK",
          bank_account_number: @transfer.receiver_bank_account,
          account_holder_name: @transfer.receiver_account_holder
        )

        # Email notifications
        begin
          TransferMailer.with(transfer_id: @transfer.id).sender_funded.deliver_later
        rescue => e
          Rails.logger.error "Transfer email failed [transfer=#{@transfer.id}]: #{e.message}"
        end

        redirect_to transfer_path(@transfer), notice: "Transfè bank #{@transfer.amount.to_i} HTG an kou! Trete nan 1-2 jou ouvrab."
      rescue WalletService::InsufficientFundsError
        redirect_to transfer_path(@transfer), alert: "Balans pòtfèy pa sifi."
      rescue WalletService::FrozenAccountError
        redirect_to transfer_path(@transfer), alert: "Pòtfèy ou jele. Tanpri kontakte sipò."
      end
      return
    end

    # ── Wallet funding (HTG only) ──
    if @transfer.htg_transfer? && params[:funding_source] == "wallet"
      wallet = current_user.ensure_wallet!

      unless wallet.sufficient_balance?(@transfer.amount)
        redirect_to transfer_path(@transfer),
                    alert: "Balans pòtfèy pa sifi. Ou bezwen #{@transfer.amount.to_i} HTG men ou gen #{wallet.htg_balance.to_i} HTG."
        return
      end

      begin
        WalletService.new(wallet).transfer_out!(
          amount: @transfer.amount,
          fee: @transfer.fee,
          transfer: @transfer
        )

        # ── BonID Per-Transaction Consent Check ──
        if BonIdService.consent_required?(@transfer) && !@consent_already_approved
          unless current_user.bonid_verified?
            # Refund — user needs BonID first
            WalletService.new(wallet).refund!(
              amount: @transfer.amount,
              asset: "htg",
              reference: @transfer,
              reason: "BonID obligatwa pou transfè >= #{BonIdService::CONSENT_THRESHOLD.to_i} HTG"
            )
            @transfer.update!(status: :failed, failure_reason: "BonID pa verifye")
            redirect_to transfer_path(@transfer),
              alert: "Pou pwoteje kont ou, montan sa a mande yon verifikasyon BonID."
            return
          end

          consent_result = BonIdService.request_consent(@transfer)

          if consent_result[:success]
            @transfer.update!(
              status: :awaiting_consent,
              funded_at: Time.current,
              funding_source: "wallet"
            )

            BonidConsentRequest.create!(
              user: current_user,
              transfer: @transfer,
              consent_token: consent_result[:consent_token],
              bonid: current_user.bonid,
              reference_id: "ZEL-transfer-#{@transfer.token}",
              amount: @transfer.amount,
              transaction_type: "p2p_transfer",
              expires_at: consent_result[:expires_at]
            )

            redirect_to transfer_path(@transfer),
              notice: "Tanpri apwouve transfè sa a nan BonID ou. Tcheke imèl ou pou kòd OTP."
            return
          else
            WalletService.new(wallet).refund!(
              amount: @transfer.amount,
              asset: "htg",
              reference: @transfer,
              reason: "BonID consent endiponib — ranbouse #{@transfer.amount.to_i} HTG"
            )
            @transfer.update!(status: :failed, failure_reason: "BonID consent endiponib")
            redirect_to transfer_path(@transfer),
              alert: "Pou pwoteje kont ou, montan sa a mande yon verifikasyon BonID."
            return
          end
        end

        @transfer.update!(
          status: :funded,
          funded_at: Time.current,
          funding_source: "wallet",
          expires_at: 72.hours.from_now
        )

        # Trigger payout (always — worker resolves receiver by cashtag, email, or phone)
        TransferPayoutWorker.perform_async(@transfer.id)

        # Real-time sound notification to receiver
        broadcast_transfer_funded(@transfer)

        # Emails
        begin
          TransferMailer.with(transfer_id: @transfer.id).sender_funded.deliver_later
          if @transfer.receiver_email.present?
            TransferMailer.with(transfer_id: @transfer.id).receiver_incoming.deliver_later
          end
        rescue => e
          Rails.logger.error "Transfer email failed [transfer=#{@transfer.id}]: #{e.message}"
        end

        TransferExpiryWorker.perform_in(73.hours, @transfer.id) if @transfer.htg_transfer?

        redirect_to transfer_path(@transfer), notice: "Transfè finansye nan pòtfèy ou! N ap voye lajan bay moun nan."
      rescue WalletService::InsufficientFundsError
        redirect_to transfer_path(@transfer), alert: "Balans pòtfèy pa sifi."
      rescue WalletService::FrozenAccountError
        redirect_to transfer_path(@transfer), alert: "Pòtfèy ou jele. Tanpri kontakte sipò."
      end
      return
    end

    # ── Business funding (HTG from business account) ──
    if @transfer.htg_transfer? && params[:funding_source] == "business"
      business = current_user.business
      wallet   = current_user.ensure_wallet!

      unless business.present? && business.sufficient_htg?(@transfer.amount)
        redirect_to transfer_path(@transfer),
                    alert: "Balans biznis pa sifi. Ou bezwen #{@transfer.amount.to_i} HTG men biznis ou gen #{business&.htg_balance.to_i} HTG."
        return
      end

      begin
        WalletService.new(wallet).withdraw_from_business!(
          business: business,
          amount: @transfer.amount,
          asset: "htg"
        )

        # Re-deposit into wallet so transfer_out! can debit it
        WalletService.new(wallet).deposit!(
          amount: @transfer.amount,
          asset: "htg",
          description: "Depo depi biznis #{business.name} pou transfè"
        )

        WalletService.new(wallet).transfer_out!(
          amount: @transfer.amount,
          fee: @transfer.fee,
          transfer: @transfer
        )

        # ── BonID Per-Transaction Consent Check (Business HTG) ──
        if BonIdService.consent_required?(@transfer) && !@consent_already_approved
          unless current_user.bonid_verified?
            WalletService.new(wallet).refund!(
              amount: @transfer.amount,
              asset: "htg",
              reference: @transfer,
              reason: "BonID obligatwa pou transfè >= #{BonIdService::CONSENT_THRESHOLD.to_i} HTG"
            )
            @transfer.update!(status: :failed, failure_reason: "BonID pa verifye")
            redirect_to transfer_path(@transfer),
              alert: "Pou pwoteje kont ou, montan sa a mande yon verifikasyon BonID."
            return
          end

          consent_result = BonIdService.request_consent(@transfer)

          if consent_result[:success]
            @transfer.update!(
              status: :awaiting_consent,
              funded_at: Time.current,
              funding_source: "business"
            )

            BonidConsentRequest.create!(
              user: current_user,
              transfer: @transfer,
              consent_token: consent_result[:consent_token],
              bonid: current_user.bonid,
              reference_id: "ZEL-transfer-#{@transfer.token}",
              amount: @transfer.amount,
              transaction_type: "p2p_transfer",
              expires_at: consent_result[:expires_at]
            )

            redirect_to transfer_path(@transfer),
              notice: "Tanpri apwouve transfè sa a nan BonID ou. Tcheke imèl ou pou kòd OTP."
            return
          else
            WalletService.new(wallet).refund!(
              amount: @transfer.amount,
              asset: "htg",
              reference: @transfer,
              reason: "BonID consent endiponib — ranbouse #{@transfer.amount.to_i} HTG"
            )
            @transfer.update!(status: :failed, failure_reason: "BonID consent endiponib")
            redirect_to transfer_path(@transfer),
              alert: "Pou pwoteje kont ou, montan sa a mande yon verifikasyon BonID."
            return
          end
        end

        @transfer.update!(
          status: :funded,
          funded_at: Time.current,
          funding_source: "business",
          expires_at: 72.hours.from_now
        )

        TransferPayoutWorker.perform_async(@transfer.id)
        broadcast_transfer_funded(@transfer)

        begin
          TransferMailer.with(transfer_id: @transfer.id).sender_funded.deliver_later
          if @transfer.receiver_email.present?
            TransferMailer.with(transfer_id: @transfer.id).receiver_incoming.deliver_later
          end
        rescue => e
          Rails.logger.error "Transfer email failed [transfer=#{@transfer.id}]: #{e.message}"
        end

        TransferExpiryWorker.perform_in(73.hours, @transfer.id)

        redirect_to transfer_path(@transfer), notice: "Transfè finansye depi biznis ou! N ap voye lajan bay moun nan."
      rescue WalletService::InsufficientFundsError
        redirect_to transfer_path(@transfer), alert: "Balans biznis pa sifi."
      rescue => e
        Rails.logger.error "Business transfer funding failed [transfer=#{@transfer.id}]: #{e.message}"
        redirect_to transfer_path(@transfer), alert: "Erè nan transfè. Tanpri eseye ankò."
      end
      return
    end

    # ── Wallet funding (USD via $zellustag) ──
    if @transfer.usd_wallet_transfer? && params[:funding_source] == "wallet"
      wallet = current_user.ensure_wallet!
      usd_amount = @transfer.crypto_amount || @transfer.net_amount

      unless wallet.sufficient_balance?("usd", usd_amount)
        redirect_to transfer_path(@transfer),
                    alert: "Balans USD pa sifi. Ou bezwen #{usd_amount} USD men ou gen #{wallet.usd_balance} USD."
        return
      end

      begin
        WalletService.new(wallet).transfer_out!(
          amount: usd_amount,
          fee: BigDecimal("0"),
          transfer: @transfer,
          asset: "usd"
        )

        # ── BonID Per-Transaction Consent Check (USD) ──
        if BonIdService.consent_required?(@transfer) && !@consent_already_approved
          unless current_user.bonid_verified?
            # Refund — user needs BonID first
            WalletService.new(wallet).refund!(
              amount: usd_amount,
              asset: "usd",
              reference: @transfer,
              reason: "BonID obligatwa pou transfè >= #{BonIdService::CONSENT_THRESHOLD.to_i} HTG"
            )
            @transfer.update!(status: :failed, failure_reason: "BonID pa verifye")
            redirect_to transfer_path(@transfer),
              alert: "Pou pwoteje kont ou, montan sa a mande yon verifikasyon BonID."
            return
          end

          consent_result = BonIdService.request_consent(@transfer)

          if consent_result[:success]
            @transfer.update!(
              status: :awaiting_consent,
              funded_at: Time.current,
              funding_source: "wallet"
            )

            BonidConsentRequest.create!(
              user: current_user,
              transfer: @transfer,
              consent_token: consent_result[:consent_token],
              bonid: current_user.bonid,
              reference_id: "ZEL-transfer-#{@transfer.token}",
              amount: usd_amount,
              transaction_type: "p2p_transfer",
              expires_at: consent_result[:expires_at]
            )

            redirect_to transfer_path(@transfer),
              notice: "Tanpri apwouve transfè sa a nan BonID ou. Tcheke imèl ou pou kòd OTP."
            return
          else
            WalletService.new(wallet).refund!(
              amount: usd_amount,
              asset: "usd",
              reference: @transfer,
              reason: "BonID consent endiponib — ranbouse #{usd_amount} USD"
            )
            @transfer.update!(status: :failed, failure_reason: "BonID consent endiponib")
            redirect_to transfer_path(@transfer),
              alert: "Pou pwoteje kont ou, montan sa a mande yon verifikasyon BonID."
            return
          end
        end

        @transfer.update!(
          status: :funded,
          funded_at: Time.current,
          funding_source: "wallet"
        )

        TransferPayoutWorker.perform_async(@transfer.id)

        # Real-time sound notification to receiver
        broadcast_transfer_funded(@transfer)

        begin
          TransferMailer.with(transfer_id: @transfer.id).sender_funded.deliver_later
        rescue => e
          Rails.logger.error "Transfer email failed [transfer=#{@transfer.id}]: #{e.message}"
        end

        redirect_to transfer_path(@transfer), notice: "Transfè USD finansye nan pòtfèy ou! N ap voye bay moun nan."
      rescue WalletService::InsufficientFundsError
        redirect_to transfer_path(@transfer), alert: "Balans USD pòtfèy pa sifi."
      rescue WalletService::FrozenAccountError
        redirect_to transfer_path(@transfer), alert: "Pòtfèy ou jele. Tanpri kontakte sipò."
      end
      return
    end

    # ── Wallet funding (USD to external 0x address) ──
    if @transfer.usd_address_transfer? && params[:funding_source] == "wallet"
      wallet = current_user.ensure_wallet!
      usd_amount = @transfer.crypto_amount || @transfer.net_amount

      unless wallet.sufficient_balance?("usd", usd_amount)
        redirect_to transfer_path(@transfer),
                    alert: "Balans USD pa sifi. Ou bezwen #{usd_amount} USD men ou gen #{wallet.usd_balance} USD."
        return
      end

      begin
        WalletService.new(wallet).transfer_out!(
          amount: usd_amount,
          fee: BigDecimal("0"),
          transfer: @transfer,
          asset: "usd"
        )

        # ── BonID Per-Transaction Consent Check (USD address) ──
        if BonIdService.consent_required?(@transfer) && !@consent_already_approved
          unless current_user.bonid_verified?
            WalletService.new(wallet).refund!(
              amount: usd_amount,
              asset: "usd",
              reference: @transfer,
              reason: "BonID obligatwa pou transfè >= #{BonIdService::CONSENT_THRESHOLD.to_i} HTG"
            )
            @transfer.update!(status: :failed, failure_reason: "BonID pa verifye")
            redirect_to transfer_path(@transfer),
              alert: "Pou pwoteje kont ou, montan sa a mande yon verifikasyon BonID."
            return
          end

          consent_result = BonIdService.request_consent(@transfer)

          if consent_result[:success]
            @transfer.update!(
              status: :awaiting_consent,
              funded_at: Time.current,
              funding_source: "wallet"
            )

            BonidConsentRequest.create!(
              user: current_user,
              transfer: @transfer,
              consent_token: consent_result[:consent_token],
              bonid: current_user.bonid,
              reference_id: "ZEL-transfer-#{@transfer.token}",
              amount: usd_amount,
              transaction_type: "p2p_transfer",
              expires_at: consent_result[:expires_at]
            )

            redirect_to transfer_path(@transfer),
              notice: "Tanpri apwouve transfè sa a nan BonID ou. Tcheke imèl ou pou kòd OTP."
            return
          else
            WalletService.new(wallet).refund!(
              amount: usd_amount,
              asset: "usd",
              reference: @transfer,
              reason: "BonID consent endiponib — ranbouse #{usd_amount} USD"
            )
            @transfer.update!(status: :failed, failure_reason: "BonID consent endiponib")
            redirect_to transfer_path(@transfer),
              alert: "Pou pwoteje kont ou, montan sa a mande yon verifikasyon BonID."
            return
          end
        end

        @transfer.update!(
          status: :funded,
          funded_at: Time.current,
          funding_source: "wallet"
        )

        # On-chain payout via treasury
        TransferPayoutWorker.perform_async(@transfer.id)

        # Real-time sound notification to receiver
        broadcast_transfer_funded(@transfer)

        begin
          TransferMailer.with(transfer_id: @transfer.id).sender_funded.deliver_later
        rescue => e
          Rails.logger.error "Transfer email failed [transfer=#{@transfer.id}]: #{e.message}"
        end

        redirect_to transfer_path(@transfer), notice: "USD finansye nan pòtfèy ou! N ap voye sou blockchain Base."
      rescue WalletService::InsufficientFundsError
        redirect_to transfer_path(@transfer), alert: "Balans USD pòtfèy pa sifi."
      rescue WalletService::FrozenAccountError
        redirect_to transfer_path(@transfer), alert: "Pòtfèy ou jele. Tanpri kontakte sipò."
      end
      return
    end

    # ── Wallet funding (Stock via $zellustag — wallet-to-wallet) ──
    if @transfer.stock_wallet_transfer? && params[:funding_source] == "wallet"
      wallet = current_user.ensure_wallet!
      stock_asset = @transfer.asset.to_s
      stock_amount = @transfer.crypto_amount || @transfer.net_amount

      unless wallet.sufficient_balance?(stock_asset, stock_amount)
        redirect_to transfer_path(@transfer),
                    alert: "Balans #{stock_asset.upcase} pa sifi. Ou bezwen #{stock_amount} #{stock_asset.upcase} men ou gen #{wallet.balance_for(stock_asset)} #{stock_asset.upcase}."
        return
      end

      begin
        WalletService.new(wallet).transfer_out!(
          amount: stock_amount,
          fee: BigDecimal("0"),
          transfer: @transfer,
          asset: stock_asset
        )

        # ── BonID Per-Transaction Consent Check (Stock) ──
        if BonIdService.consent_required?(@transfer) && !@consent_already_approved
          unless current_user.bonid_verified?
            WalletService.new(wallet).refund!(
              amount: stock_amount,
              asset: stock_asset,
              reference: @transfer,
              reason: "BonID obligatwa pou transfè >= #{BonIdService::CONSENT_THRESHOLD.to_i} HTG"
            )
            @transfer.update!(status: :failed, failure_reason: "BonID pa verifye")
            redirect_to transfer_path(@transfer),
              alert: "Pou pwoteje kont ou, montan sa a mande yon verifikasyon BonID."
            return
          end

          consent_result = BonIdService.request_consent(@transfer)

          if consent_result[:success]
            @transfer.update!(
              status: :awaiting_consent,
              funded_at: Time.current,
              funding_source: "wallet"
            )

            BonidConsentRequest.create!(
              user: current_user,
              transfer: @transfer,
              consent_token: consent_result[:consent_token],
              bonid: current_user.bonid,
              reference_id: "ZEL-transfer-#{@transfer.token}",
              amount: @transfer.amount,
              transaction_type: "p2p_transfer",
              expires_at: consent_result[:expires_at]
            )

            redirect_to transfer_path(@transfer),
              notice: "Tanpri apwouve transfè sa a nan BonID ou. Tcheke imèl ou pou kòd OTP."
            return
          else
            WalletService.new(wallet).refund!(
              amount: stock_amount,
              asset: stock_asset,
              reference: @transfer,
              reason: "BonID consent endiponib — ranbouse #{stock_amount} #{stock_asset.upcase}"
            )
            @transfer.update!(status: :failed, failure_reason: "BonID consent endiponib")
            redirect_to transfer_path(@transfer),
              alert: "Pou pwoteje kont ou, montan sa a mande yon verifikasyon BonID."
            return
          end
        end

        @transfer.update!(
          status: :funded,
          funded_at: Time.current,
          funding_source: "wallet"
        )

        TransferPayoutWorker.perform_async(@transfer.id)

        # Real-time sound notification to receiver
        broadcast_transfer_funded(@transfer)

        begin
          TransferMailer.with(transfer_id: @transfer.id).sender_funded.deliver_later
        rescue => e
          Rails.logger.error "Transfer email failed [transfer=#{@transfer.id}]: #{e.message}"
        end

        redirect_to transfer_path(@transfer), notice: "Transfè #{stock_asset.upcase} finansye nan pòtfèy ou! N ap voye bay moun nan."
      rescue WalletService::InsufficientFundsError
        redirect_to transfer_path(@transfer), alert: "Balans #{stock_asset.upcase} pòtfèy pa sifi."
      rescue WalletService::FrozenAccountError
        redirect_to transfer_path(@transfer), alert: "Pòtfèy ou jele. Tanpri kontakte sipò."
      end
      return
    end

    # ── MonCash funding (existing path) ──
    order_id = "transfer-#{@transfer.id}-#{Time.now.to_i}"
    url = create_moncash_payment(@transfer.amount.to_i, order_id)

    if url
      @transfer.update!(moncash_order_id: order_id, funding_source: "moncash")
      redirect_to url, allow_other_host: true
    else
      @transfer.update!(status: :failed, failure_reason: "MonCash pa disponib")
      redirect_to transfer_path(@transfer), alert: "MonCash pa disponib kounye a. Tanpri eseye ankò."
    end
  end

  # ── GET /transfers/:token/success — MonCash callback ──
  # ── GET /transfers/:token/consent_status — AJAX polling for BonID consent ──
  def consent_status
    @transfer = find_transfer_for_current_user(params[:id] || params[:token])
    consent = @transfer.bonid_consent_request

    if consent.nil?
      render json: { status: "not_required" }
    elsif consent.approved?
      render json: { status: "approved" }
    elsif consent.denied?
      render json: { status: "denied", reason: "Sitwayen refize konsentisyon" }
    elsif consent.expired? || consent.timed_out?
      render json: { status: "expired" }
    else
      render json: { status: "pending", expires_at: consent.expires_at&.iso8601 }
    end
  end

  # ── POST /transfers/:token/recheck_consent — Manual BonID API poll (fallback when webhook fails) ──
  def recheck_consent
    @transfer = find_transfer_for_current_user(params[:id] || params[:token])
    consent = @transfer.bonid_consent_request

    unless consent&.pending?
      redirect_to transfer_path(@transfer)
      return
    end

    result = BonIdService.check_consent(consent.consent_token)

    unless result[:success]
      redirect_to transfer_path(@transfer),
        alert: "Nou pa t ka verifye estati a ak BonID. Tanpri eseye ankò."
      return
    end

    case result[:status]
    when "approved"
      consent.update!(status: :approved, signature: result[:signature], decided_at: result[:decided_at])

      if @transfer.awaiting_consent?
        if @transfer.funded_at.present?
          @transfer.update!(status: :funded)
          TransferPayoutWorker.perform_async(@transfer.id)
          Rails.logger.info "BonID recheck: consent approved for #{@transfer.token} — payout triggered"
        else
          @transfer.update!(status: :pending)
          Rails.logger.info "BonID recheck: consent approved for #{@transfer.token} — awaiting PIN"
        end
      end

      redirect_to transfer_path(@transfer), notice: "Konsentisyon BonID apwouve!"

    when "denied"
      consent.update!(status: :denied, decided_at: result[:decided_at])

      if @transfer.awaiting_consent?
        @transfer.update!(status: :failed, failure_reason: "Sitwayen refize konsentisyon BonID")
        refund_held_funds(@transfer, "Konsentisyon BonID refize") if @transfer.funded_at.present?
        NotificationService.transfer_failed(@transfer)
      end

      redirect_to transfer_path(@transfer), alert: "Konsentisyon BonID refize."

    when "expired"
      consent.update!(status: :expired)

      if @transfer.awaiting_consent?
        @transfer.update!(status: :failed, failure_reason: "Konsentisyon BonID ekspire")
        refund_held_funds(@transfer, "Konsentisyon BonID ekspire") if @transfer.funded_at.present?
        NotificationService.transfer_failed(@transfer)
      end

      redirect_to transfer_path(@transfer), alert: "Konsentisyon BonID ekspire."

    else
      redirect_to transfer_path(@transfer),
        notice: "Konsentisyon toujou an kou. Tanpri apwouve nan BonID ou epi eseye ankò."
    end
  end

  def success
    @transfer = find_transfer_for_current_user(params[:id] || params[:token])
    @claim_url = claim_transfer_url(@transfer.token)

    if @transfer.funded? || @transfer.sent? || @transfer.completed?
      flash.now[:notice] = "Peman an deja konfime."
    elsif @transfer.pending?
      verified = MoncashService.verify_order(@transfer.moncash_order_id)

      if verified
        # ── BonID Per-Transaction Consent Check (MonCash) ──
        if BonIdService.consent_required?(@transfer) && !@consent_already_approved
          unless current_user.bonid_verified?
            @transfer.update!(status: :failed, failure_reason: "BonID pa verifye")
            flash.now[:alert] = "Pou pwoteje kont ou, montan sa a mande yon verifikasyon BonID. Kontakte sipò pou ranbousman MonCash."
            render :show
            return
          end

          consent_result = BonIdService.request_consent(@transfer)

          if consent_result[:success]
            @transfer.update!(
              status: :awaiting_consent,
              funded_at: Time.current,
              funding_source: "moncash",
              expires_at: 72.hours.from_now
            )

            BonidConsentRequest.create!(
              user: current_user,
              transfer: @transfer,
              consent_token: consent_result[:consent_token],
              bonid: current_user.bonid,
              reference_id: "ZEL-transfer-#{@transfer.token}",
              amount: @transfer.amount,
              transaction_type: "p2p_transfer",
              expires_at: consent_result[:expires_at]
            )

            flash.now[:notice] = "Peman MonCash konfime! Tanpri apwouve transfè sa a nan BonID ou. Tcheke imèl ou pou kòd OTP."
            render :show
            return
          else
            @transfer.update!(status: :failed, failure_reason: "BonID consent endiponib")
            flash.now[:alert] = "Pou pwoteje kont ou, montan sa a mande yon verifikasyon BonID. Kontakte sipò pou ranbousman MonCash."
            render :show
            return
          end
        end

        @transfer.update!(status: :funded, funded_at: Time.current, expires_at: 72.hours.from_now)

        if @transfer.htg_transfer?
          # HTG payout via MonCash
          if @transfer.receiver_phone.present?
            TransferPayoutWorker.perform_async(@transfer.id)
          end
          # If no phone, receiver claims via /t/:token
        else
          # Crypto: send from treasury to receiver wallet
          TransferPayoutWorker.perform_async(@transfer.id)
        end

        begin
          TransferMailer.with(transfer_id: @transfer.id).sender_funded.deliver_later
          if @transfer.receiver_email.present?
            TransferMailer.with(transfer_id: @transfer.id).receiver_incoming.deliver_later
          end
        rescue => e
          Rails.logger.error "Transfer email failed [transfer=#{@transfer.id}]: #{e.message}"
        end

        TransferExpiryWorker.perform_in(73.hours, @transfer.id) if @transfer.htg_transfer?

        receiver_label = @transfer.receiver_name.presence || @transfer.receiver_display
        flash.now[:notice] = "Mèsi! Peman ou konfime. N ap voye #{@transfer.asset_label} bay #{receiver_label}."
      else
        flash.now[:alert] = "Nou pa t kapab verifye peman ou ak MonCash. Tanpri kontakte sipò."
      end
    else
      flash.now[:alert] = "Transfè sa a pa ka trete."
    end

    render :show
  end

  # ── GET /t/:token — Public claim page (no auth) ──
  def claim
    @transfer = Transfer.find_by!(token: params[:token])
    @transfer.mark_expired_if_needed!
  end

  # ── POST /t/:token/claim — Receiver submits MonCash number ──
  def claim_confirm
    @transfer = Transfer.find_by!(token: params[:token])
    @transfer.mark_expired_if_needed!

    unless @transfer.funded?
      flash[:alert] = case @transfer.status
      when "completed" then "Transfè sa a deja konplete."
      when "expired"   then "Transfè sa a ekspire."
      when "claimed"   then "Transfè sa a deja reklame. N ap trete l."
      else "Transfè sa a pa disponib."
      end
      redirect_to claim_transfer_path(@transfer.token)
      return
    end

    phone = params[:receiver_phone].to_s.gsub(/[^\d]/, "")
    unless phone.match?(/\A509\d{8}\z/)
      flash[:alert] = "Tanpri antre yon nimewo MonCash valid (509 + 8 chif)."
      redirect_to claim_transfer_path(@transfer.token)
      return
    end

    @transfer.update!(receiver_phone: phone, status: :claimed)
    TransferPayoutWorker.perform_async(@transfer.id)

    flash[:notice] = "Nimewo MonCash ou anrejistre. N ap voye #{number_to_currency(@transfer.net_amount, unit: 'HTG ', precision: 0)} ba ou!"
    redirect_to claim_transfer_path(@transfer.token)
  end

  private

  # Find a transfer the current user can view (as sender OR receiver)
  def find_transfer_for_current_user(token)
    # Try as sender
    transfer = current_user.transfers.find_by(token: token)
    return transfer if transfer

    # Try as receiver (matched by cashtag)
    if current_user.cashtag.present?
      transfer = Transfer.where("LOWER(receiver_cashtag) = ?", current_user.cashtag.downcase).find_by(token: token)
      return transfer if transfer
    end

    # Not found — raise 404
    current_user.transfers.find_by!(token: token)
  end

  def transfer_params
    params.require(:transfer).permit(:receiver_name, :receiver_phone, :receiver_email, :receiver_wallet_address, :receiver_cashtag, :receiver_bank_account, :receiver_bank_name, :receiver_account_holder, :amount, :note)
  end

  # Broadcast real-time notification to receiver (plays ka-ching sound)
  def broadcast_transfer_funded(transfer)
    receiver = find_receiver_user_for(transfer)
    return unless receiver

    amount_label = if transfer.crypto_amount.present?
                     "#{transfer.crypto_amount} #{transfer.asset.to_s.upcase}"
    else
                     "#{transfer.amount.to_i} HTG"
    end

    Rails.logger.info "[Zèllus] Broadcasting transfer_received to user #{receiver.id} (#{amount_label})"

    avatar_url = if current_user.avatar.attached?
                   Rails.application.routes.url_helpers.rails_blob_url(current_user.avatar, only_path: true)
    elsif current_user.bonid_photo_url.present?
                   current_user.bonid_photo_url
    end

    # Instant real-time preview — NO sound here because the money hasn't
    # arrived yet. The TransferPayoutWorker credits the wallet and then
    # calls NotificationService.transfer_received WITH sound — that's
    # the authoritative notification when funds actually land.
    NotificationChannel.broadcast_to(
      receiver,
      {
        title: "$#{current_user.cashtag || current_user.display_name} peye w #{amount_label}",
        type: "transfer_received",
        play_sound: false,
        avatar_url: avatar_url
      }
    )
  rescue => e
    Rails.logger.error "[Zèllus] Broadcast error: #{e.message}"
  end

  def find_receiver_user_for(transfer)
    if transfer.receiver_cashtag.present?
      User.find_by("LOWER(cashtag) = ?", transfer.receiver_cashtag.downcase)
    elsif transfer.receiver_email.present?
      User.find_by(email: transfer.receiver_email)
    elsif transfer.receiver_phone.present?
      User.find_by(phone_number: transfer.receiver_phone)
    end
  end

  def load_saved_methods
    @moncash_methods = current_user.payment_methods.active.mobile_wallet.moncash.order(created_at: :desc)
    @crypto_methods  = current_user.payment_methods.active.crypto_wallet.base.order(created_at: :desc)
    @bank_methods    = current_user.payment_methods.active.bank_account.where(provider: :unibank).order(created_at: :desc)
  end

  def load_rates
    @usd_htg_rate = RateService.buy_rate        # HTG per 1 USD
    # ETH/BTC/stock rates disabled (HTG + USD only mode)
    @eth_htg_rate  = 0
    @wbtc_htg_rate = 0
    @stock_htg_rates = %w[tslax nvdax aaplx coinx googlx].index_with { |_| 0 }
  rescue => e
    Rails.logger.error "TransfersController rate load failed: #{e.message}"
    @usd_htg_rate = 135.50
    @eth_htg_rate  = 0
    @wbtc_htg_rate = 0
    @stock_htg_rates = %w[tslax nvdax aaplx coinx googlx].index_with { |_| 0 }
  end

  def exchange_rate_for(asset_type)
    case asset_type
    when "usd" then @usd_htg_rate
    when "eth"  then @eth_htg_rate
    when "wbtc" then @wbtc_htg_rate
    when "tslax", "nvdax", "aaplx", "coinx", "googlx"
      @stock_htg_rates[asset_type]
    else nil
    end
  end

  STOCK_ASSETS = %w[tslax nvdax aaplx coinx googlx].freeze

  def resolve_receiver(transfer, asset_type)
    # ── Unified lookup: $zellustag, phone, or email ──
    # Works for HTG, USD, and stock assets (zellustag lookup enables wallet-to-wallet)
    lookup = params[:receiver_lookup].to_s.strip
    if lookup.present? && (%w[htg usd].include?(asset_type) || STOCK_ASSETS.include?(asset_type))
      clean = lookup.delete_prefix("$")
      if clean.match?(/\A509\d{8}\z/) && asset_type == "htg"
        transfer.receiver_phone = clean
      elsif clean.match?(URI::MailTo::EMAIL_REGEXP) && asset_type == "htg"
        transfer.receiver_email = clean
      elsif clean.match?(/\A[a-zA-Z0-9]{5,20}\z/)
        transfer.receiver_cashtag = clean.downcase
        found = User.find_by("LOWER(cashtag) = ?", clean.downcase)
        if found
          transfer.receiver_email = found.email if asset_type == "htg"
          transfer.receiver_name = found.display_name if transfer.receiver_name.blank?
          transfer.payout_method = "wallet" # Zèllus-to-Zèllus: no fee
        end
      end
    end

    if asset_type == "htg"
      # ── Cashtag already resolved → wallet-to-wallet, skip phone/bank ──
      return if transfer.receiver_cashtag.present?

      # ── Bank transfer mode ──
      if params[:receiver_mode] == "bank"
        # Saved bank method
        bank_method_id = params[:bank_method_id].to_s.strip
        if bank_method_id.present? && bank_method_id != "other"
          method = current_user.payment_methods.active.bank_account.find_by(id: bank_method_id)
          if method
            transfer.receiver_bank_account  = method.bank_account_number
            transfer.receiver_bank_name     = method.bank_name || "UNIBANK"
            transfer.receiver_account_holder = method.account_holder_name
          end
        end
        # Manual bank inputs override
        manual_acct = params.dig(:transfer, :receiver_bank_account).to_s.strip
        transfer.receiver_bank_account = manual_acct if manual_acct.present?
        manual_bank = params.dig(:transfer, :receiver_bank_name).to_s.strip
        transfer.receiver_bank_name = manual_bank.presence || "UNIBANK"
        manual_holder = params.dig(:transfer, :receiver_account_holder).to_s.strip
        transfer.receiver_account_holder = manual_holder if manual_holder.present?
        return
      end

      # Check saved MonCash method
      method_id = params[:moncash_method_id].to_s.strip
      if method_id.present? && method_id != "other"
        method = current_user.payment_methods.active.mobile_wallet.find_by(id: method_id)
        transfer.receiver_phone = method.account_number.to_s.gsub(/[^\d]/, "") if method
      end
      # Manual phone takes precedence if provided
      manual_phone = params.dig(:transfer, :receiver_phone).to_s.gsub(/[^\d]/, "")
      transfer.receiver_phone = manual_phone if manual_phone.present?
    elsif transfer.receiver_cashtag.blank?
      # Crypto without $zellustag: fall through to wallet address
      method_id = params[:crypto_method_id].to_s.strip
      if method_id.present? && method_id != "other"
        method = current_user.payment_methods.active.crypto_wallet.find_by(id: method_id)
        transfer.receiver_wallet_address = method.wallet_address if method
      end
      # Manual address takes precedence if provided
      manual_addr = params.dig(:transfer, :receiver_wallet_address).to_s.strip
      transfer.receiver_wallet_address = manual_addr if manual_addr.present?
    end
  end

  def send_limit_error(amount)
    value = amount.to_f
    return "Antre yon montan valid." if value <= 0

    if @transfer&.asset == "usd"
      # Amount arrives in HTG (frontend converts USD→HTG), convert back to USD for limit check
      rate = exchange_rate_for("usd") || 1
      usd_value = rate > 0 ? value / rate : value
      return "Montan minimòm se 1 USD." if usd_value < 1
      return "Montan maksimòm se 500 USD pa tranzaksyon." if usd_value > 500
    elsif !@transfer&.crypto_transfer?
      return "Montan minimòm se #{Transfer::SEND_MIN_HTG} HTG." if value < Transfer::SEND_MIN_HTG
      return "Montan maksimòm se #{number_with_delimiter(Transfer::SEND_MAX_HTG)} HTG pa tranzaksyon." if value > Transfer::SEND_MAX_HTG
    end

    nil
  end

  def daily_limit_error(amount)
    remaining = current_user.daily_transfer_remaining
    limit     = current_user.daily_transfer_limit
    return nil if amount.to_f <= remaining

    "Ou depase limit jounalye ou (#{number_with_delimiter(limit.to_i)} HTG/jou). Ou ka voye #{number_with_delimiter(remaining.to_i)} HTG ankò jodi a."
  end

  # Refund held funds to the correct asset wallet (mirrors webhook controller logic)
  def refund_held_funds(transfer, reason)
    if transfer.funding_source == "moncash"
      Rails.logger.warn "MonCash-funded transfer #{transfer.token} denied/expired — requires manual admin refund"
      return
    end

    wallet = transfer.user.wallet
    return unless wallet

    if transfer.usd_wallet_transfer? || transfer.usd_address_transfer?
      refund_amount = transfer.crypto_amount || transfer.net_amount
      refund_asset = "usd"
    elsif transfer.stock_wallet_transfer?
      refund_amount = transfer.crypto_amount || transfer.net_amount
      refund_asset = transfer.asset.to_s
    else
      refund_amount = transfer.amount
      refund_asset = "htg"
    end

    WalletService.new(wallet).refund!(
      amount: refund_amount,
      asset: refund_asset,
      reference: transfer,
      reason: "#{reason} — ranbouse"
    )
  end

  def create_moncash_payment(amount, order_id)
    token = MoncashService.get_token
    return nil unless token

    base_url = MoncashService::BASE_URL
    gateway  = MoncashService::GATEWAY_BASE_URL

    conn = Faraday.new(url: "#{base_url}/Api/v1/CreatePayment")
    payload = { amount: amount.to_i, orderId: order_id }.to_json

    response = conn.post do |req|
      req.headers["Authorization"] = "Bearer #{token}"
      req.headers["Content-Type"]  = "application/json"
      req.headers["Accept"]        = "application/json"
      req.body = payload
    end

    if response.success?
      body = JSON.parse(response.body)
      payment_token = body.dig("payment_token", "token")
      "#{gateway}/Payment/Redirect?token=#{payment_token}"
    else
      Rails.logger.error "MonCash Transfer Payment Failed: #{response.status} #{response.body}"
      nil
    end
  rescue => e
    Rails.logger.error "MonCash Transfer Payment Error: #{e.message}"
    nil
  end
end
