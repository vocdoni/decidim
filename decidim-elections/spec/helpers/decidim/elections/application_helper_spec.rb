# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    describe ApplicationHelper do
      let(:organization) { create(:organization) }

      before do
        allow(helper).to receive(:current_organization).and_return(organization)
      end

      describe "#question_description" do
        subject(:rendered_description) { helper.render_question_description(question) }

        context "when the description is blank" do
          let(:question) { build(:election_question, description: { "en" => "" }) }

          it { is_expected.to be_nil }
        end

        context "when the description has plain text" do
          let(:question) { create(:election_question, description: { "en" => "More info" }) }

          it { is_expected.to eq('<div class="rich-text-display">More info</div>') }
        end

        context "when the description includes markup" do
          let(:question) { build(:election_question, description: { "en" => "<strong>Intro</strong>" }) }

          it "keeps the allowed tags" do
            expect(rendered_description).to eq('<div class="rich-text-display"><strong>Intro</strong></div>')
          end
        end

        context "when the description includes images" do
          let(:question) { build(:election_question, description: { "en" => '<p>Check this image:</p><img src="image.jpg" alt="Example">' }) }

          it "keeps the image tags" do
            expect(rendered_description).to include("<img")
            expect(rendered_description).to include('src="image.jpg"')
            expect(rendered_description).to include('alt="Example"')
          end
        end
      end

      describe "#voted_by_current_user?" do
        let(:component) { create(:elections_component) }
        let(:election) { create(:election, :published, :with_internal_users_census, :ongoing, component:) }
        let(:current_user) { create(:user, :confirmed, organization: component.organization) }
        let(:voter_uid) { current_user.to_global_id.to_s }

        before do
          allow(helper).to receive(:current_user).and_return(current_user)
          allow(helper).to receive(:session).and_return({})
        end

        context "when the backend is a server-side backend" do
          it "returns false when no vote exists" do
            expect(helper.voted_by_current_user?(election)).to be(false)
          end

          it "returns true when a vote exists for the voter_uid derived from the census" do
            question = create(:election_question, election:)
            response_option = create(:election_response_option, question:)
            create(:election_vote, voter_uid:, question:, response_option:)
            expect(helper.voted_by_current_user?(election)).to be(true)
          end
        end

        context "when the backend is a client-side backend" do
          let(:backend_name) { :test_voted_backend }
          let(:voted_result) { false }

          before do
            vr = voted_result
            Decidim::Elections.voting_backends.register(backend_name) do |manifest|
              manifest.transport = :client
              manifest.client_adapter = "test_backend"
              manifest.client_script = "/test/booth.js"
              manifest.vote_overwrite = false
              manifest.applies_to { |e| e.id == election.id }
              manifest.booth_config { |_e, **_opts| {} }
              manifest.csp_directives { |_e| {} }
              manifest.voted { |_e, _uid| vr }
            end
          end

          after do
            Decidim::Elections.voting_backends.manifests.delete_if { |m| m.name == backend_name }
          end

          it "delegates to the backend voted? method" do
            expect(helper.voted_by_current_user?(election)).to be(false)
          end

          context "when the backend reports voted" do
            let(:voted_result) { true }

            it "returns true" do
              expect(helper.voted_by_current_user?(election)).to be(true)
            end
          end

          context "when session[:voter_uid] is unset but session_attributes are present" do
            let(:session_attrs) { { "some_attr" => "value" } }

            before do
              allow(helper).to receive(:session).and_return({ session_attributes: session_attrs })
            end

            it "computes voter_uid from the census session attributes" do
              # The census voter_uid call receives the session_attributes hash, not empty
              allow(election.census).to receive(:voter_uid).with(election, session_attrs, current_user:).and_return(voter_uid)
              helper.voted_by_current_user?(election)
              expect(election.census).to have_received(:voter_uid).with(election, session_attrs, current_user:)
            end
          end
        end
      end
    end
  end
end
