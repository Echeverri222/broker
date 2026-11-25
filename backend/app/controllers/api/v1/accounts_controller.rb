module Api
  module V1
    class AccountsController < ApplicationController
      before_action :authenticate!

      def reset
        Accounts::Reset.call(current_account, confirm: params[:confirm])
        render json: Presenters.user(current_user.reload)
      end
    end
  end
end
