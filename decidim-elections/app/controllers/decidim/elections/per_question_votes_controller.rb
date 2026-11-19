# frozen_string_literal: true

module Decidim
  module Elections
    # Provides access to election resources so that users can participate Election.where(component: current_component).published.lections.
    class PerQuestionVotesController < Decidim::Elections::ApplicationController
      include Decidim::Elections::UsesVotesBooth
      include Decidim::FormFactory

      before_action do
        redirect_to Decidim::EngineRouter.main_proxy(current_component).new_election_vote_path(election) unless election.per_question?
      end

      before_action only: :receipt do
        redirect_to(action: :waiting) if waiting_for_next_question?
      end

      # A client-side backend casts from the booth, so the server-side question
      # form is never shown. The JSON status poll of `show` is read-only.
      before_action only: [:show, :update], if: -> { voting_backend.client? } do
        redirect_to(**next_vote_step_action) unless action_name == "show" && request.format.json?
      end

      before_action only: [:show, :update] do
        redirect_to(**next_vote_step_action) unless question.voting_enabled? || request.format.json?
      end

      before_action only: :booth, if: -> { voting_backend.client? } do
        redirect_to(**next_vote_step_action) if open_questions.none?
      end

      # Show the voting form for the given question
      # Responds to HTML (render the form) and JSON (check question status for polling)
      def show
        enforce_permission_to(:create, :vote, election:)

        respond_to do |format|
          format.html
          format.json do
            render json: question_status_response
          end
        end
      end

      # Saves the vote for the current question and redirect to the next question
      def update
        enforce_permission_to(:create, :vote, election:)

        response_ids = params.dig(:response, question.id.to_s)
        requeue_following_questions
        votes_buffer[question.id.to_s] = response_ids
        CastVotes.call(election, { question.id.to_s => response_ids }, voter_uid) do
          on(:ok) do
            session[:voter_uid] = voter_uid
            flash[:notice] = t("votes.cast.success", scope: "decidim.elections")
            redirect_to(**next_vote_step_action)
          end

          on(:invalid) do
            action = { action: :show, id: question }
            action = next_vote_step_action unless question.voting_enabled?

            flash[:alert] = t("votes.cast.invalid", scope: "decidim.elections")
            redirect_to(**action)
          end
        end
      end

      # If the election is per-question, this action will be called to show the waiting page
      # while the user waits for the next question to be available.
      # If the election is not per-question, this action will redirect to the next question
      def waiting
        enforce_permission_to(:create, :vote, election:)

        redirect_action = waiting_for_next_question? ? nil : next_vote_step_action
        respond_to do |format|
          format.html do
            redirect_to(**redirect_action) if redirect_action.present?
          end

          format.json do
            render json: waiting_status_response(redirect_action)
          end
        end
      end

      private

      # we cannot memoize this method because it can change during the voting process
      def session_pending_questions
        election.questions.unpublished_results.where.not(id: votes_buffer.keys)
      end

      # Questions the admin has opened and whose results are not published yet.
      # With a client-side backend the server does not know what was cast, so
      # these drive the flow instead of the session's votes buffer.
      def open_questions
        election.questions.enabled.unpublished_results
      end

      # The client-side booth asks only the open questions; the other actions
      # still need to find closed ones.
      def questions
        return super unless action_name == "booth" && voting_backend.client?

        @questions ||= open_questions
      end

      def waiting_for_next_question?
        return open_questions.none? && election.questions.unpublished_results.any? if voting_backend.client?

        session_pending_questions.any? && session_pending_questions.enabled.none?
      end

      def next_vote_step_action
        return next_client_booth_step if voting_backend.client?
        return { action: :receipt } unless session_pending_questions.any?

        next_question = session_pending_questions.enabled.first.presence || question.next_question.presence
        return { action: :waiting } if next_question.blank?

        { action: :show, id: next_question }
      end

      def next_client_booth_step
        return { action: :receipt } if election.questions.unpublished_results.none?
        return { action: :waiting } if open_questions.none?

        { action: :booth }
      end

      # A booth already showing its receipt polls this to learn which questions
      # opened since the page was rendered, and adds them in place.
      def waiting_status_response(redirect_action)
        status = { url: redirect_action ? url_for(**redirect_action) : nil }
        return status unless voting_backend.client?

        status.merge(open_question_ids: open_questions.pluck(:id).map(&:to_s),
                     more_may_open: election.questions.disabled.any?)
      end

      # Returns JSON response with question voting status for client-side polling.
      # Used to redirect users when a question's voting is closed while they are on the voting page.
      def question_status_response
        if question.voting_enabled?
          { voting_enabled: true, redirect_url: nil }
        else
          redirect_action = next_vote_step_action
          { voting_enabled: false, redirect_url: url_for(**redirect_action) }
        end
      end

      def requeue_following_questions
        election.questions
                .where("position > ?", question.position)
                .pluck(:id)
                .each { |id| votes_buffer.delete(id.to_s) }
      end
    end
  end
end
