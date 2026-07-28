# frozen_string_literal: true

module MitsubachiInfra
  module Deployment
    StepResult = Struct.new(:name, :succeeded, :started_at, :completed_at, :output_files, :details,
                            keyword_init: true) do
      def to_h
        {
          name: name,
          succeeded: succeeded,
          started_at: started_at&.iso8601,
          completed_at: completed_at&.iso8601,
          elapsed_seconds: started_at && completed_at ? (completed_at - started_at).round(3) : nil,
          output_files: Array(output_files),
          details: details || {}
        }
      end
    end
  end
end
