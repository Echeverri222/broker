module Api
  module V1
    class AccountsController < ApplicationController
      before_action :authenticate!
      rate_limit to: 3, within: 1.day, only: :reset, by: -> { limit_key }, name: "reset", with: -> { rate_limited!(86_400) } # SEC-02
      rate_limit to: 5, within: 15.minutes, only: %i[password destroy], by: -> { limit_key }, name: "credentials", with: -> { rate_limited!(900) }
      rate_limit to: 5, within: 1.hour, only: :export, by: -> { limit_key }, name: "export", with: -> { rate_limited!(3600) }

      def reset
        Accounts::Reset.call(current_account, confirm: params[:confirm])
        audit(:account_reset)
        render json: Presenters.user(current_user.reload)
      end

      # SES-06
      def password
        unless current_user.authenticate(params[:current_password].to_s)
          raise ApiError.new(:validation_failed, "Your current password is incorrect.")
        end
        current_user.update!(password: params[:password].to_s)
        current_user.sessions.where.not(id: current_session.id).delete_all # SES-04: other devices are signed out
        audit(:password_changed)
        UserMailer.password_changed(current_user).deliver_later
        head :no_content
      end

      # SES-08
      def destroy
        raise ApiError.new(:validation_failed, 'Type "DELETE" to confirm.') unless params[:confirm] == "DELETE"
        raise ApiError.new(:validation_failed, "Your password is incorrect.") unless current_user.authenticate(params[:password].to_s)
        user = current_user
        audit(:account_deleted, user: user)
        user.anonymise!
        cookies.delete(COOKIE)
        head :no_content
      end

      # SES-10: the user's own data only.
      def export
        account = current_account
        render json: {
          exported_at: Fmt.iso(Clock.now),
          user: { name: current_user.name, email: current_user.email, created_at: Fmt.iso(current_user.created_at) },
          deposits: account.deposits.order(:id).map { |d| Presenters.deposit(d) },
          orders: account.orders.includes(:asset).order(:id).map { |o| Presenters.order(o) },
          positions: account.positions.includes(:asset).order(:id).map { |p| Presenters.position(p) }
        }
      end

      # NTF-02
      def preferences
        allowed = params.permit(:notify_order_filled, :notify_order_rejected)
        current_user.update!(allowed.to_h.transform_values { |v| ActiveModel::Type::Boolean.new.cast(v) })
        render json: Presenters.user(current_user.reload)
      end
    end
  end
end
