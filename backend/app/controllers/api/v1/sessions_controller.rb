module Api
  module V1
    class SessionsController < ApplicationController
      rate_limit to: 10, within: 3.minutes, only: :create, by: -> { client_ip }, with: -> { rate_limited!(180) }
      # SEC-03: also limited per email, so rotating IPs does not help a password guesser.
      rate_limit to: 10, within: 15.minutes, only: :create, name: "email", with: -> { rate_limited!(900) },
                 by: -> { params[:email].to_s.strip.downcase.presence || client_ip }
      DUMMY = BCrypt::Password.create("dummy-password-for-timing")

      def create
        user = User.find_by(email: params[:email].to_s.strip.downcase)
        # AUTH-03: same work and same message whether or not the email exists.
        authenticated = user ? user.authenticate(params[:password].to_s) : (DUMMY == params[:password].to_s && false)
        authenticated = false if user&.deleted?
        unless authenticated
          audit(:login_failure, user: user, email_known: user.present?)
          raise ApiError.new(:unauthenticated, "Incorrect email or password.")
        end
        raise ApiError.new(:account_disabled, "This account has been disabled. Contact support.") if user.disabled?
        start_session!(user)
        audit(:login_success, user: user)
        render json: Presenters.user(user)
      end

      def destroy
        audit(:logout) if current_user
        current_session&.destroy
        cookies.delete(COOKIE)
        head :no_content
      end
    end
  end
end
