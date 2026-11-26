module Api
  module V1
    module Admin
      # ADM-01: admin endpoints need the `admin` flag AND a password check within the last 15 minutes (per session).
      # Every admin action writes an audit event (SEC-09). A non-admin gets 404, so the endpoints are not discoverable.
      class BaseController < ApplicationController
        REAUTH_WINDOW = 15.minutes
        before_action :authenticate!
        before_action :require_admin!
        before_action :require_recent_reauth!, except: :reauth

        def reauth
          unless current_user.authenticate(params[:password].to_s)
            audit(:login_failure, admin_reauth: true)
            raise ApiError.new(:unauthenticated, "Incorrect password.")
          end
          current_session.update_columns(reauthenticated_at: Clock.now)
          audit(:admin_reauth)
          render json: { reauthenticated_until: Fmt.iso(Clock.now + REAUTH_WINDOW) }
        end

        private

        def require_admin!
          raise ApiError.new(:not_found, "Not found") unless current_user.admin
        end

        def require_recent_reauth!
          at = current_session.reauthenticated_at
          return if at && at > Clock.now - REAUTH_WINDOW
          raise ApiError.new(:reauth_required, "Confirm your password to use admin tools.")
        end

        def present_user(u)
          { id: u.id, name: u.name, email: u.email, verified: u.verified?, admin: u.admin, disabled: u.disabled?, deleted: u.deleted?,
            created_at: Fmt.iso(u.created_at), active_sessions: u.sessions.active.count,
            account: u.account && { cash: Fmt.money(u.account.cash), reserved_cash: Fmt.money(u.account.reserved_cash),
                                    positions: u.account.positions.count, orders: u.account.orders.count } }
        end
      end
    end
  end
end
