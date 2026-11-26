module Api
  module V1
    # SES-05. `create` answers 202 with an empty body whether or not the email exists, and sends mail from a job, so the
    # response and its timing do not reveal which emails are registered.
    class PasswordResetsController < ApplicationController
      rate_limit to: 5, within: 1.hour, only: :create, by: -> { client_ip }, with: -> { rate_limited!(3600) }
      rate_limit to: 3, within: 1.hour, only: :create, name: "email", with: -> { rate_limited!(3600) },
                 by: -> { params[:email].to_s.strip.downcase.presence || client_ip }
      rate_limit to: 10, within: 1.hour, only: :update, by: -> { client_ip }, name: "update", with: -> { rate_limited!(3600) }

      def create
        user = User.find_by(email: params[:email].to_s.strip.downcase)
        if user && !user.deleted? && !user.disabled?
          UserMailer.password_reset(user).deliver_later
          audit(:password_reset_requested, user: user)
        end
        head :accepted
      end

      def update
        user = User.find_by_token_for(:password_reset, params[:token].to_s)
        raise ApiError.new(:invalid_token, "This reset link is invalid or has expired. Request a new one.") if user.nil? || user.deleted?
        user.update!(password: params[:password].to_s)
        user.update_columns(verified_at: Clock.now) unless user.verified? # reading the email proves ownership
        user.sessions.delete_all
        audit(:password_reset, user: user)
        UserMailer.password_changed(user).deliver_later
        head :no_content
      end
    end
  end
end
