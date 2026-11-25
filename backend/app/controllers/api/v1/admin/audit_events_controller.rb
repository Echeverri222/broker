module Api
  module V1
    module Admin
      # SEC-09: read-only. Append-only at the model level too.
      class AuditEventsController < BaseController
        def index
          scope = AuditEvent.order(id: :desc)
          scope = scope.where(user_id: params[:user_id]) if params[:user_id].present?
          scope = scope.where(event: params[:event]) if params[:event].present?
          render json: { events: scope.limit(100).map { |e|
            { id: e.id, event: e.event, user_id: e.user_id, ip_address: e.ip_address, metadata: e.metadata, created_at: Fmt.iso(e.created_at) }
          } }
        end
      end
    end
  end
end
