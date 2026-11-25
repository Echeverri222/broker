module Api
  module V1
    class SignupsController < ApplicationController
      rate_limit to: 5, within: 1.hour, only: :create, by: -> { client_ip }, with: -> { rate_limited!(3600) }

      # AUTH-01: user, account, initial deposit and first snapshot in one transaction.
      def create
        user = User.new(params.permit(:name, :email, :password))
        User.transaction do
          user.save!
          account = user.create_account!(cash: 0)
          Accounts::Provision.call(account)
        end
        user.account.reload
        start_session!(user)
        audit(:signup, user: user)
        UserMailer.verify_email(user).deliver_later # SES-07
        render json: Presenters.user(user), status: :created
      rescue ActiveRecord::RecordNotUnique
        raise ApiError.new(:validation_failed, "Email has already been taken")
      end
    end
  end
end
