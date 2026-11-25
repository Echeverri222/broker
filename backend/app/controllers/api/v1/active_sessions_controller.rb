module Api
  module V1
    # SES-04: the signed-in user's own sessions. Other users' sessions are unreachable (scoped through current_user).
    class ActiveSessionsController < ApplicationController
      before_action :authenticate!

      def index
        sessions = current_user.sessions.active.order(last_seen_at: :desc).map { |s| present(s) }
        render json: { sessions: sessions }
      end

      def destroy
        target = current_user.sessions.find(params[:id])
        current = target.id == current_session.id
        target.destroy
        audit(:session_revoked, session_id: target.id)
        cookies.delete(COOKIE) if current
        head :no_content
      end

      def destroy_others
        n = current_user.sessions.where.not(id: current_session.id).delete_all
        audit(:sessions_revoked, count: n)
        head :no_content
      end

      private

      def present(s)
        { id: s.id, current: s.id == current_session.id, user_agent: s.user_agent, ip_address: s.ip_address,
          created_at: Fmt.iso(s.created_at), last_seen_at: Fmt.iso(s.last_seen_at), expires_at: Fmt.iso(s.expires_at) }
      end
    end
  end
end
