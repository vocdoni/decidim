# frozen_string_literal: true

module Decidim
  module Elections
    module Admin
      class UpdateQuestionStatus < Decidim::Command
        def initialize(action, question)
          @action = action.to_sym
          @question = question
        end

        def call
          return broadcast(:invalid) unless action.in?([:enable_voting, :publish_results])
          # No-op guard: already in the requested state → succeed without events or DB write.
          return broadcast(:ok, question) if already_in_requested_state?
          return broadcast(:invalid) if invalid_publish?

          with_events(with_transaction: true) do
            update_status
            question.save!
            publish_election_results_if_last!
          end

          broadcast(:ok, question)
        rescue StandardError => e
          Rails.logger.error "#{e.class.name}: #{e.message}"
          broadcast(:invalid)
        end

        protected

        def event_arguments
          { question: question, action: action }
        end

        private

        attr_reader :action, :question

        def already_in_requested_state?
          case action
          when :enable_voting    then question.voting_enabled_at.present?
          when :publish_results  then question.published_results_at.present?
          end
        end

        # Publishing results of a question that was never opened for voting is invalid.
        def invalid_publish?
          action == :publish_results && question.voting_enabled_at.nil?
        end

        def update_status
          case action
          when :enable_voting
            question.voting_enabled_at = Time.current
          when :publish_results
            question.published_results_at = Time.current
          end
        end

        # B3: when the last unpublished question of a per_question election is published,
        # also set election.published_results_at in the same transaction.
        def publish_election_results_if_last!
          return unless action == :publish_results

          election = question.election
          return unless election.per_question?
          return if election.published_results_at?
          return unless election.questions.where(published_results_at: nil).none?

          election.update_columns(published_results_at: Time.current)
        end
      end
    end
  end
end
