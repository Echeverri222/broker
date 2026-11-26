module Api
  module V1
    # SES-07
    class EmailVerificationsController < ApplicationController
      before_action :authenticate!, only: :create
      rate_limit to: 3, within: 1.hour, only: :create, by: -> { limit_key }, with: -> { rate_limited!(3600) }

      def create
        UserMailer.verify_email(current_user).deliver_later unless current_user.verified?
        head :accepted
      end

      def update
        user = User.find_by_token_for(:email_verification, params[:token].to_s)
        raise ApiError.new(:invalid_token, "This confirmation link is invalid or has expired.") if user.nil? || user.deleted?
        user.update_columns(verified_at: Clock.now) unless user.verified?
        audit(:email_verified, user: user)
        head :no_content
      end
    end
  end
end
