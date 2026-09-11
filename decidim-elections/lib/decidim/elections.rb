# frozen_string_literal: true

require "decidim/elections/admin"
require "decidim/elections/engine"
require "decidim/elections/admin_engine"
require "decidim/elections/component"

module Decidim
  # Base module for the elections engine.
  module Elections
    autoload :CensusManifest, "decidim/elections/census_manifest"

    # Public: Stores the registry of components
    def self.census_registry
      @census_registry ||= ManifestRegistry.new("elections/census")
    end

    # Public: Extends the values accepted by Election#results_availability.
    #
    # External Decidim modules can register additional options (e.g.
    # `:blockchain_backed`) from their engine initializer. The Rails `enum`
    # is defined by Decidim::Elections::Engine's `config.after_initialize`
    # hook with the union of all registered values, so any option registered
    # during boot is baked into the enum before the first request.
    def self.register_results_availability(name)
      name = name.to_s
      results_availability_options << name unless results_availability_options.include?(name)
    end

    # Public: Mutable list of every registered results_availability option.
    # Seeded on first access with the three built-in values. Kept in sync
    # with the Election model's frozen defaults constant by convention —
    # not by direct reference, because this method can run at engine-init
    # time (before Zeitwerk has autoloaded the model), and touching the
    # constant there would raise NameError.
    def self.results_availability_options
      @results_availability_options ||= %w(real_time per_question after_end)
    end
  end
end
