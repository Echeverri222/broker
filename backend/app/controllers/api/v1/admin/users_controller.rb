module Api
  module V1
    module Admin
      # ADM-02: look up, disable/enable, revoke sessions, trigger a password reset. Deliberately NO way to edit
      # balances, positions or orders: corrections are an audited, separate process (PRD v4 D8).
      class UsersController < BaseController
        def index
          q = params[:q].to_s.strip
          scope = User.includes(:account).order(:id)
          scope = scope.where("email ILIKE :q OR name ILIKE :q OR id::text = :id", q: "%#{User.sanitize_sql_like(q)}%", id: q) if q.present?
          render json: { users: scope.limit(50).map { |u| present_user(u) } }
        end

        def show = render(json: present_user(User.includes(:account).find(params[:id])))

        def disable
          user = User.find(params[:id])
          raise ApiError.new(:validation_failed, "You cannot disable yourself.") if user.id == current_user.id
          user.update_columns(disabled_at: Clock.now)
          user.sessions.delete_all
          audit(:admin_user_disabled, target_user_id: user.id)
          render json: present_user(user.reload)
        end

        def enable
          user = User.find(params[:id])
          user.update_columns(disabled_at: nil)
          audit(:admin_user_enabled, target_user_id: user.id)
          render json: present_user(user.reload)
        end

        def revoke_sessions
          user = User.find(params[:id])
          n = user.sessions.delete_all
          audit(:admin_sessions_revoked, target_user_id: user.id, count: n)
          render json: present_user(user.reload)
        end

        def password_reset
          user = User.find(params[:id])
          UserMailer.password_reset(user).deliver_later unless user.deleted?
          audit(:password_reset_requested, target_user_id: user.id, by_admin: true)
          head :accepted
        end
      end
    end
  end
end
