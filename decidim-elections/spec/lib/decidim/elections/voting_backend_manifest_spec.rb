# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    describe VotingBackendManifest do
      subject(:manifest) { described_class.new(name: :test_backend) }

      describe "attributes and defaults" do
        it "has the given name" do
          expect(manifest.name).to eq(:test_backend)
        end

        it "defaults live_tally to true" do
          expect(manifest.live_tally).to be(true)
        end

        it "allows live_tally to be set to false" do
          manifest.live_tally = false
          expect(manifest.live_tally).to be(false)
        end
      end

      describe "validation" do
        it "is valid with a name" do
          expect(manifest).to be_valid
        end

        it "is invalid without a name" do
          manifest.name = nil
          expect(manifest).not_to be_valid
        end
      end

      describe "#applies_to?" do
        let(:election) { double("election") }

        it "returns false when no applies_to block is set" do
          expect(manifest.applies_to?(election)).to be(false)
        end

        it "calls the registered block" do
          manifest.applies_to { |e| e == election }
          expect(manifest.applies_to?(election)).to be(true)
          expect(manifest.applies_to?(double("other"))).to be(false)
        end
      end
    end

    describe ".voting_backends registry" do
      let!(:test_backend_name) { :"test_backend_#{SecureRandom.hex(4)}" }

      after do
        registry = Decidim::Elections.voting_backends
        registry.manifests.reject! { |m| m.name == test_backend_name }
      end

      it "can register and find a backend by name" do
        Decidim::Elections.voting_backends.register(test_backend_name) { |m| m.live_tally = false }
        found = Decidim::Elections.voting_backends.find(test_backend_name)
        expect(found).to be_a(VotingBackendManifest)
        expect(found.name).to eq(test_backend_name)
      end

      it "has the :decidim backend registered by default (via engine initializer)" do
        expect(Decidim::Elections.voting_backends.find(:decidim)).to be_a(VotingBackendManifest)
      end

      describe ".voting_backend_for" do
        let(:election) { build(:election) }

        it "returns the :decidim backend when no other backend applies" do
          backend = Decidim::Elections.voting_backend_for(election)
          expect(backend.name).to eq(:decidim)
        end

        it "returns the first non-decidim backend that applies" do
          Decidim::Elections.voting_backends.register(test_backend_name) do |m|
            m.applies_to { |_e| true }
          end
          backend = Decidim::Elections.voting_backend_for(election)
          expect(backend.name).to eq(test_backend_name)
        end
      end
    end
  end
end
