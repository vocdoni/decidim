# frozen_string_literal: true

module Decidim
  module Elections
    # Describes how an election's ballots are cast. The built-in `:decidim`
    # backend is the server-side booth (`CastVotes`); other backends claim the
    # elections they handle through `applies_to`.
    class VotingBackendManifest
      include ActiveModel::Model
      include Decidim::AttributeObject::Model

      attribute :name, Symbol
      # Whether the backend exposes running vote tallies (false: results only once published).
      attribute :live_tally, Boolean, default: true

      validates :name, presence: true

      # |election| -> Boolean. Which elections this backend claims.
      def applies_to(&block)
        @applies_to = block
      end

      def applies_to?(election)
        @applies_to ? @applies_to.call(election) : false
      end
    end
  end
end
