module Api
  module V1
    class DepositsController < ApplicationController
      before_action :authenticate!

      def index
        render json: { deposits: current_account.deposits.order(created_at: :desc, id: :desc).limit(100).map { |d| Presenters.deposit(d) } }
      end

      def create
        result = Deposits::Create.call(account: current_account, amount: params.require(:amount),
                                       idempotency_key: request.headers["Idempotency-Key"])
        render json: Presenters.deposit(result.deposit).merge(cash: Fmt.money(current_account.reload.cash)),
               status: result.created ? :created : :ok
      end
    end
  end
end
