# frozen_string_literal: true

module Decidim
  module Elections
    # Provides access to election resources so that users can participate Election.where(component: current_component).published.lections.
    module UsesVotesBooth
      extend ActiveSupport::Concern

      included do
        include UsesCensusAccess

        layout "decidim/election_booth"
        helper_method :questions, :question, :response_chosen?, :votes_buffer, :voting_backend

        before_action :append_voting_backend_csp_directives

        before_action except: [:new, :create, :receipt] do
          next if session_authenticated?

          redirect_to exit_path, alert: t("votes.not_authorized", scope: "decidim.elections")
        end

        before_action only: :new do
          redirect_to first_ballot_step if session_authenticated?
        end

        # If the election has a census manifest that a requires authentication, render the auth form
        def new
          enforce_permission_to(:create, :vote, election:)

          @form = election.census.form_instance({}, election:, current_user:)
          render "decidim/elections/votes/new"
        end

        # If the election has a census manifest that requires authentication
        # create the session attributes for subsequent automatic validation
        def create
          enforce_permission_to(:create, :vote, election:)

          @form = election.census.form_instance(params, election:, current_user:)
          if @form.valid?
            session[:session_attributes] = @form.attributes
            redirect_to first_ballot_step
          else
            flash[:alert] =
              @form.errors.full_messages.join("<br>").presence || t("failed", scope: "decidim.elections.votes.check_census")
            redirect_to action: :new
          end
        end
      end

      # Shows the receipt page
      def receipt
        if params[:exit].present?
          votes_buffer.clear
          session_attributes.clear
          return redirect_to(exit_path)
        end

        enforce_permission_to(:create, :vote, election:)

        votes_buffer.clear unless election.per_question?

        return redirect_to(exit_path) unless election.votes.exists?(voter_uid: session[:voter_uid])

        render "decidim/elections/votes/receipt"
      end

      # Client-side booth: every question, the confirm step and the receipt in
      # one page. Answers stay in the browser and are cast by the backend's
      # JavaScript adapter; nothing is posted back here.
      def booth
        enforce_permission_to(:create, :vote, election:)
        return redirect_to(action: :show, id: question) unless voting_backend.client?

        @booth_config = voting_backend.booth_config_for(election, voter_uid:, current_user:)
        render "decidim/elections/votes/booth"
      end

      private

      def voting_backend
        election.voting_backend
      end

      def first_ballot_step
        return { action: :booth } if voting_backend.client?

        { action: :show, id: question }
      end

      def append_voting_backend_csp_directives
        voting_backend.csp_directives_for(election).each do |directive, values|
          Array(values).each { |value| content_security_policy.append_csp_directive(directive.to_s, value) }
        end
      end

      def questions
        @questions ||= election.questions
      end

      def question
        @question ||= questions.find_by(id: params[:id]) || questions.first
      end

      def votes_buffer
        session[:votes_buffer] ||= {}
      end

      def response_chosen?(response_option)
        response_ids = if votes_buffer.has_key?(question.id.to_s)
                         votes_buffer[question.id.to_s]
                       else
                         previous_responses[question.id.to_s]
                       end
        return false if response_ids.blank?

        response_ids.include?(response_option.id.to_s)
      end

      def previous_responses
        @previous_responses ||= election.questions.to_h do |question|
          [question.id.to_s, question.votes.where(voter_uid:).pluck(:response_option_id).map(&:to_s)]
        end
      end
    end
  end
end
