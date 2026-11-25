module Api
  module V1
    class MeController < ApplicationController
      before_action :authenticate!
      def show = render(json: Presenters.user(current_user))
    end
  end
end
