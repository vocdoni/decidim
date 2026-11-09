# frozen_string_literal: true

module Decidim
  module Elections
    module Admin
      class PublishElection < Decidim::Command
        # A command to publish an election.
        #
        #  election - Decidim::Elections::Election
        # Current_user - the user performing the action
        def initialize(election, current_user)
          @election = election
          @current_user = current_user
        end

        # Executes the command. Broadcasts these events:
        #
        # - :ok when everything is valid.
        # - :invalid if the form was not valid and we could not proceed.
        #
        # Returns nothing.
        def call
          return broadcast(:invalid) if election.published?

          with_events(with_transaction: true) do
            publish_election
          end

          broadcast(:ok, election)
        end

        protected

        def event_arguments
          { election: election, current_user: current_user }
        end

        private

        attr_reader :election, :current_user

        def publish_election
          @election = Decidim.traceability.perform_action!(
            :publish,
            election,
            current_user,
            visibility: "all"
          ) do
            election.publish!
            election
          end
        end
      end
    end
  end
end
