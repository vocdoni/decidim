# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    describe "per-question election with a client-side voting backend" do
      let(:organization) { component.organization }
      let(:component) { create(:elections_component, :published) }
      let(:user) { create(:user, :confirmed, organization:) }
      let(:election) { create(:election, :published, :with_internal_users_census, :per_question, :ongoing, component:) }
      let!(:open_question) { create(:election_question, :with_response_options, :voting_enabled, election:) }
      let!(:closed_question) { create(:election_question, :with_response_options, election:) }
      let(:headers) { { "HOST" => organization.host } }
      let(:router) { Decidim::EngineRouter.main_proxy(component) }
      let(:booth_path) { router.booth_election_per_question_votes_path(election_id: election.id) }
      let(:waiting_path) { router.waiting_election_per_question_votes_path(election_id: election.id) }
      let(:receipt_path) { router.receipt_election_per_question_votes_path(election_id: election.id) }
      let(:question_path) { router.election_per_question_vote_path(election_id: election.id, id: open_question.id) }
      let(:backend_name) { :"test_client_backend_#{SecureRandom.hex(4)}" }
      let(:transport) { :client }

      before do
        client = transport == :client
        Decidim::Elections.voting_backends.register(backend_name) do |manifest|
          manifest.transport = transport
          manifest.client_adapter = "test_backend" if client
          manifest.applies_to { |e| e.id == election.id }
        end
        login_as user, scope: :user
      end

      after do
        Decidim::Elections.voting_backends.manifests.reject! { |manifest| manifest.name == backend_name }
      end

      it "sends an authenticated voter from the census step to the booth" do
        get(router.new_election_per_question_vote_path(election_id: election.id), headers:)
        expect(response).to redirect_to(booth_path)
      end

      describe "the booth" do
        it "is routed to the booth action, not to a question, and shows only the open questions" do
          get(booth_path, headers:)
          expect(response).to have_http_status(:ok)
          expect(response.body).to include("data-voting-booth")
          expect(response.body).to include("data-question-id=\"#{open_question.id}\"")
          expect(response.body).not_to include("data-question-id=\"#{closed_question.id}\"")
        end

        it "sends the voter to the waiting room while no question is open" do
          open_question.update!(voting_enabled_at: nil)
          get(booth_path, headers:)
          expect(response).to redirect_to(waiting_path)
        end

        it "sends the voter to the receipt once every question has published results" do
          election.questions.each { |question| question.update!(published_results_at: Time.current) }
          get(booth_path, headers:)
          expect(response).to redirect_to(receipt_path)
        end
      end

      describe "the server-side question steps" do
        it "redirects the question form to the booth" do
          get(question_path, headers:)
          expect(response).to redirect_to(booth_path)
        end

        it "keeps answering the JSON status poll" do
          get(question_path, params: { format: :json }, headers:)
          expect(response).to have_http_status(:ok)
          expect(response.parsed_body["voting_enabled"]).to be(true)
        end

        it "does not cast on the server" do
          expect(CastVotes).not_to receive(:call)
          patch(question_path, params: { response: { open_question.id.to_s => [open_question.response_options.first.id.to_s] } }, headers:)
          expect(response).to redirect_to(booth_path)
        end
      end

      describe "the waiting room" do
        it "sends the voter to the booth when a question is open" do
          get(waiting_path, headers:)
          expect(response).to redirect_to(booth_path)
        end

        it "lists the open question ids as JSON" do
          get(waiting_path, params: { format: :json }, headers:)
          json = response.parsed_body
          expect(json["url"]).to end_with(booth_path)
          expect(json).to include("open_question_ids" => [open_question.id.to_s], "more_may_open" => true)
        end

        it "has no URL to follow while no question is open" do
          open_question.update!(voting_enabled_at: nil)
          get(waiting_path, params: { format: :json }, headers:)
          expect(response.parsed_body).to include("url" => nil, "open_question_ids" => [])
        end

        context "with a server-side backend" do
          let(:transport) { :server }

          it "answers with the next step URL only" do
            get(waiting_path, params: { format: :json }, headers:)
            expect(response.parsed_body.keys).to eq(["url"])
          end
        end
      end
    end
  end
end
