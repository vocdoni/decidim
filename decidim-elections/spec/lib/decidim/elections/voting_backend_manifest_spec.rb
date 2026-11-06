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

        it "defaults to :server transport" do
          expect(manifest.transport).to eq(:server)
        end

        it "defaults vote_overwrite to true" do
          expect(manifest.vote_overwrite).to be(true)
        end

        it "defaults supports_per_question to true" do
          expect(manifest.supports_per_question).to be(true)
        end
      end

      describe "validation" do
        it "is valid with a name and server transport" do
          expect(manifest).to be_valid
        end

        it "is valid with client transport when client_adapter is set" do
          manifest.transport = :client
          manifest.client_adapter = "my_adapter"
          expect(manifest).to be_valid
        end

        it "is invalid without a name" do
          manifest.name = nil
          expect(manifest).not_to be_valid
        end

        it "is invalid with an unknown transport" do
          manifest.transport = :unknown
          expect(manifest).not_to be_valid
        end

        it "is invalid as :client without client_adapter" do
          manifest.transport = :client
          manifest.client_adapter = nil
          expect(manifest).not_to be_valid
          expect(manifest.errors[:client_adapter]).to be_present
        end
      end

      describe "#client?" do
        it "returns false for :server transport" do
          manifest.transport = :server
          expect(manifest.client?).to be(false)
        end

        it "returns true for :client transport" do
          manifest.transport = :client
          manifest.client_adapter = "my_adapter"
          expect(manifest.client?).to be(true)
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

      describe "#booth_config_for" do
        let(:election) { double("election") }
        let(:voter_uid) { "uid-123" }
        let(:user) { double("user") }

        it "returns an empty hash when no block is set" do
          expect(manifest.booth_config_for(election, voter_uid: voter_uid, current_user: user)).to eq({})
        end

        it "calls the registered block with the election and keyword args" do
          manifest.booth_config { |e, voter_uid:, current_user:| { election: e, uid: voter_uid, user: current_user } }
          result = manifest.booth_config_for(election, voter_uid: voter_uid, current_user: user)
          expect(result).to eq(election: election, uid: voter_uid, user: user)
        end
      end

      describe "#voted?" do
        let(:election) { build(:election) }
        let(:voter_uid) { "uid-abc" }

        context "when no voted block is set" do
          it "delegates to election.votes.exists?" do
            expect(election.votes).to receive(:exists?).with(voter_uid: voter_uid).and_return(false)
            expect(manifest.voted?(election, voter_uid)).to be(false)
          end
        end

        context "when a voted block is set" do
          it "calls the block" do
            manifest.voted { |_e, _uid| true }
            expect(manifest.voted?(election, voter_uid)).to be(true)
          end
        end
      end

      describe "#csp_directives_for" do
        let(:election) { double("election") }

        it "returns an empty hash when no block is set" do
          expect(manifest.csp_directives_for(election)).to eq({})
        end

        it "calls the registered block" do
          manifest.csp_directives { |_e| { "connect-src" => ["https://api.example.com"] } }
          expect(manifest.csp_directives_for(election)).to eq("connect-src" => ["https://api.example.com"])
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
        Decidim::Elections.voting_backends.register(test_backend_name) { |m| m.transport = :server }
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
            m.transport = :server
            m.applies_to { |_e| true }
          end
          backend = Decidim::Elections.voting_backend_for(election)
          expect(backend.name).to eq(test_backend_name)
        end
      end
    end
  end
end
