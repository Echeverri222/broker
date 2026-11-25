module Api
  module V1
    class SessionsController < ApplicationController
      rate_limit to: 10, within: 3.minutes, only: :create, by: -> { request.remote_ip }, with: -> { rate_limited! }
      DUMMY = BCrypt::Password.create("dummy-password-for-timing")

      def create
        user = User.find_by(email: params[:email].to_s.strip.downcase)
        # AUTH-03: same work and same message whether or not the email exists.
        authenticated = user ? user.authenticate(params[:password].to_s) : (DUMMY == params[:password].to_s && false)
        unless authenticated
          raise ApiError.new(:unauthenticated, "Incorrect email or password.")
        end
        start_session!(user)
        render json: Presenters.user(user)
      end

      def destroy
        current_session&.destroy
        cookies.delete(COOKIE)
        head :no_content
      end
    end
  end
end
