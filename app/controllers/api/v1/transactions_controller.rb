module Api
  module V1
    class TransactionsController < BaseController
      before_action -> { api_rate_limit!(limit: 60) }

      MAX_PER_PAGE = 100

      # GET /api/v1/transactions
      def index
        require_scope!("transactions:read")
        return if performed?

        wallet = current_user.wallet
        unless wallet
          return render json: { success: true, transactions: [], meta: { page: 1, per_page: 25, total: 0 } }
        end

        entries = wallet.wallet_ledger_entries.recent_first

        # Filter by asset
        if params[:asset].present?
          asset = params[:asset].to_s.downcase
          entries = entries.where(asset: asset)
        end

        # Filter by entry type
        if params[:type].present?
          entry_type = params[:type].to_s
          if WalletLedgerEntry::ENTRY_TYPES.include?(entry_type)
            entries = entries.where(entry_type: entry_type)
          end
        end

        # Filter by date range
        if params[:since].present?
          begin
            since_date = Time.iso8601(params[:since])
            entries = entries.where("created_at >= ?", since_date)
          rescue ArgumentError
            # Ignore invalid date
          end
        end

        if params[:until].present?
          begin
            until_date = Time.iso8601(params[:until])
            entries = entries.where("created_at <= ?", until_date)
          rescue ArgumentError
            # Ignore invalid date
          end
        end

        # Pagination
        page = [ params[:page].to_i, 1 ].max
        per_page = params[:per_page].to_i
        per_page = 25 if per_page <= 0
        per_page = MAX_PER_PAGE if per_page > MAX_PER_PAGE
        total = entries.count
        entries = entries.offset((page - 1) * per_page).limit(per_page)

        render json: {
          success: true,
          transactions: entries.map { |e| serialize_entry(e) },
          meta: { page: page, per_page: per_page, total: total }
        }
      end

      private

      def serialize_entry(entry)
        {
          id: entry.token,
          entry_type: entry.entry_type,
          amount: entry.amount.to_s,
          asset: entry.asset,
          balance_after: entry.balance_after.to_s,
          description: entry.description,
          source_context: entry.source_context,
          created_at: entry.created_at.iso8601
        }
      end
    end
  end
end
