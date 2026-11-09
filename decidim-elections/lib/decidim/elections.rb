# frozen_string_literal: true

require "decidim/elections/admin"
require "decidim/elections/engine"
require "decidim/elections/admin_engine"
require "decidim/elections/component"

module Decidim
  # Base module for the elections engine.
  module Elections
    autoload :CensusManifest, "decidim/elections/census_manifest"
    autoload :VotingBackendManifest, "decidim/elections/voting_backend_manifest"

    # Public: Stores the registry of components
    def self.census_registry
      @census_registry ||= ManifestRegistry.new("elections/census")
    end

    # Public: How ballots are cast. `:decidim` is the server-side booth.
    def self.voting_backends
      @voting_backends ||= ManifestRegistry.new("elections/voting_backends")
    end

    # Public: The backend of an election: the first non-default backend that
    # claims it, otherwise `:decidim`.
    def self.voting_backend_for(election)
      claimed = voting_backends.manifests.find { |manifest| manifest.name != :decidim && manifest.applies_to?(election) }
      claimed || voting_backends.find(:decidim)
    end
  end
end
