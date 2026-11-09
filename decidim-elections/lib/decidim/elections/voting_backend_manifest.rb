# frozen_string_literal: true

module Decidim
  module Elections
    # Describes how an election's ballots are cast. The built-in `:decidim`
    # backend is the server-side booth (`CastVotes`). A `:client` backend keeps
    # the answers in the page and hands them to a registered JavaScript adapter,
    # so the server never sees identity and choices together.
    class VotingBackendManifest
      include ActiveModel::Model
      include Decidim::AttributeObject::Model

      attribute :name, Symbol
      # :server (CastVotes) or :client (JavaScript adapter)
      attribute :transport, Symbol, default: :server
      attribute :cast_command, String, default: "Decidim::Elections::CastVotes"
      # Name passed to `registerVotingBackend` by the adapter (:client only)
      attribute :client_adapter, String
      # Same-origin script or pack that registers the adapter (:client only)
      attribute :client_script, String
      # Rendered hidden in the booth; the adapter shows it when needed (e.g. OTP)
      attribute :pre_ballot_partial, String
      # Extra receipt content (codes, explorer links)
      attribute :receipt_partial, String
      attribute :vote_overwrite, Boolean, default: true
      attribute :supports_per_question, Boolean, default: true

      validates :name, presence: true
      validates :transport, inclusion: { in: [:server, :client] }
      validates :client_adapter, presence: true, if: :client?

      def client? = transport.to_sym == :client

      # |election| -> Boolean. Which elections this backend claims.
      def applies_to(&block)
        @applies_to = block
      end

      def applies_to?(election)
        @applies_to ? @applies_to.call(election) : false
      end

      # |election, voter_uid:, current_user:| -> Hash, serialised as JSON into the booth page.
      def booth_config(&block)
        @booth_config = block
      end

      def booth_config_for(election, voter_uid:, current_user:)
        @booth_config ? @booth_config.call(election, voter_uid:, current_user:) : {}
      end

      # |election, voter_uid| -> Boolean
      def voted(&block)
        @voted = block
      end

      def voted?(election, voter_uid)
        return @voted.call(election, voter_uid) if @voted

        election.votes.exists?(voter_uid:)
      end

      # |election| -> { "connect-src" => [...] }
      def csp_directives(&block)
        @csp_directives = block
      end

      def csp_directives_for(election)
        @csp_directives ? @csp_directives.call(election).to_h : {}
      end
    end
  end
end
