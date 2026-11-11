# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    describe VotesController do
      let(:user) { create(:user, :confirmed, organization: component.organization) }
      let(:component) { create(:elections_component) }
      let(:election) { create(:election, :published, :with_internal_users_census, :ongoing, component:) }
      let!(:question) { create(:election_question, :with_response_options, :voting_enabled, election:) }

      let(:params) do
        { component_id: component.id, election_id: election.id }
      end

      before do
        request.env["decidim.current_organization"] = component.organization
        request.env["decidim.current_participatory_space"] = component.participatory_space
        request.env["decidim.current_component"] = component
        allow(controller).to receive(:current_participatory_space).and_return(component.participatory_space)
        allow(controller).to receive(:current_component).and_return(component)
        sign_in user
        session[:voter_uid] = user.to_global_id.to_s
      end

      describe "GET booth" do
        render_views

        let(:backend_name) { :test_booth_backend }

        def register_backend(vote_overwrite:)
          Decidim::Elections.voting_backends.register(backend_name) do |manifest|
            manifest.transport = :client
            manifest.client_adapter = "test_backend"
            manifest.client_script = "/test/booth.js"
            manifest.vote_overwrite = vote_overwrite
            manifest.applies_to { |e| e.id == election.id }
            manifest.booth_config { |_e, **_opts| {} }
            manifest.csp_directives { |_e| {} }
          end
        end

        before do
          # Route helpers used in the booth view need stubbing in controller specs
          # because the engine routes are not fully wired in this context.
          allow(controller).to receive(:exit_path).and_return("/")
          allow(controller).to receive(:election_path).and_return("/")
          allow(controller).to receive(:elections_path).and_return("/")
        end

        after do
          # Remove the test backend so it does not bleed into other examples.
          Decidim::Elections.instance_variable_set(:@voting_backends, nil)
        end

        context "when the voting backend allows vote overwrite" do
          before { register_backend(vote_overwrite: true) }

          it "shows the overwrite notice in the receipt section" do
            get(:booth, params:)
            expect(response).to have_http_status(:ok)
            expect(response.body).to include(
              I18n.t("description", scope: "decidim.elections.votes.receipt")
            )
          end
        end

        context "when the voting backend does not allow vote overwrite" do
          before { register_backend(vote_overwrite: false) }

          it "does not show the overwrite notice in the receipt section" do
            get(:booth, params:)
            expect(response).to have_http_status(:ok)
            expect(response.body).not_to include(
              I18n.t("description", scope: "decidim.elections.votes.receipt")
            )
          end

          it "ships the stock cast success flash for the receipt step" do
            get(:booth, params:)
            expect(response.body).to include("data-booth-cast-flash")
            expect(response.body).to include(I18n.t("success", scope: "decidim.elections.votes.cast"))
          end
        end
      end
    end
  end
end
