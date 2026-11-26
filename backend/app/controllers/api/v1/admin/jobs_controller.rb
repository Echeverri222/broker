module Api
  module V1
    module Admin
      # ADM-04: queue depth and failed jobs, with retry / discard.
      class JobsController < BaseController
        def index
          render json: { available: QueueStats.available? ? true : false, depth: QueueStats.depth_by_queue,
                         oldest_ready_seconds: QueueStats.oldest_ready_age&.round, failed: QueueStats.failed }
        end

        def retry
          failed = SolidQueue::FailedExecution.find(params[:id])
          failed.retry
          audit(:admin_job_retried, failed_execution_id: params[:id])
          head :no_content
        end

        def discard
          failed = SolidQueue::FailedExecution.find(params[:id])
          failed.discard
          audit(:admin_job_discarded, failed_execution_id: params[:id])
          head :no_content
        end
      end
    end
  end
end
