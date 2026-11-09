# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    # Covers the #booth action added to UsesVotesBooth (demo/integrated-booth):
    #   - census gate: unauthenticated users are redirected
    #   - non-client backends redirect to the first question (old flow)
    #   - client backends render the booth page with booth_config
    #   - CSP directives from the backend are appended to the response header
    describe VotesController do
      let(:user) { create(:user, :confirmed, organization: component.organization) }
      let(:component) { create(:elections_component) }
      let(:election) { create(:election, :published, :with_internal_users_census, :ongoing, component:) }
      let!(:question) { create(:election_question, :with_response_options, :voting_enabled, election:) }

      let(:params) do
        {
          component_id: component.id,
          election_id: election.id
        }
      end

      let(:election_path) { Decidim::EngineRouter.main_proxy(component).election_path(id: election.id) }

      before do
        request.env["decidim.current_organization"] = component.organization
        request.env["decidim.current_participatory_space"] = component.participatory_space
        request.env["decidim.current_component"] = component
        allow(controller).to receive(:current_participatory_space).and_return(component.participatory_space)
        allow(controller).to receive(:current_component).and_return(component)
        allow(controller).to receive(:election_path).and_return(election_path)
        allow(controller).to receive(:new_election_vote_path).and_return(election_path)
      end

      describe "GET booth" do
        context "when the user is not authenticated (census gate)" do
          it "redirects to exit_path with not_authorized alert" do
            get(:booth, params:)
            expect(response).to redirect_to(election_path)
          end
        end

        context "when the user is authenticated" do
          before { sign_in user }

          context "when the election uses the :decidim (server-side) backend" do
            # :decidim is a :server backend — booth must redirect back to the question flow.
            it "redirects to the first question (non-client backend keeps old flow)" do
              expect(controller).to receive(:redirect_to).with({ action: :show, id: question })
              get(:booth, params:)
            end
          end

          context "when the election uses a :client backend" do
            let(:client_backend_name) { :"test_client_#{SecureRandom.hex(4)}" }

            before do
              # Register a client backend that claims every election.
              Decidim::Elections.voting_backends.register(client_backend_name) do |m|
                m.transport = :client
                m.client_adapter = "test_adapter"
                m.applies_to { |_e| true }
                m.booth_config { |e, voter_uid:, current_user:| { process: e.id } }
                m.csp_directives { |_e| { "connect-src" => ["https://csp.example.com"] } }
              end
              # Reset cached backend on the election.
              election.instance_variable_set(:@voting_backend, nil)
            end

            after do
              Decidim::Elections.voting_backends.manifests.reject! { |m| m.name == client_backend_name }
            end

            it "renders the booth page" do
              get(:booth, params:)
              expect(response).to have_http_status(:ok)
              expect(subject).to render_template("decidim/elections/votes/booth")
            end

            it "assigns booth_config from the backend" do
              get(:booth, params:)
              expect(assigns(:booth_config)).to include(process: election.id)
            end

            it "appends the backend's CSP directives to connect-src" do
              get(:booth, params:)
              csp = response.headers["Content-Security-Policy"]
              expect(csp).to include("csp.example.com")
            end
          end
        end
      end
    end
  end
end
