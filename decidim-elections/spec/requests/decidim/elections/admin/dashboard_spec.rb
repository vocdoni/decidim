# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Admin
      describe "admin dashboard" do
        let(:organization) { component.organization }
        let(:component) { create(:elections_component) }
        let(:admin) { create(:user, :admin, :confirmed, organization:) }
        let(:headers) { { "HOST" => organization.host } }
        let(:dashboard_path) { Decidim::EngineRouter.admin_proxy(component).dashboard_election_path(election) }

        before { login_as admin, scope: :user }

        # The dashboard replaces the 0-vote table with an informational note when
        # the backend has no live tally, until the question's (or election's) results
        # are published.
        describe "results-hidden-until-published note" do
          let!(:election) { create(:election, :published, :ongoing, :per_question, :with_token_csv_census, component:) }
          let!(:question) { create(:election_question, :with_response_options, election:) }
          let(:backend_name) { :"test_live_tally_#{SecureRandom.hex(4)}" }

          def register_backend(live_tally:)
            Decidim::Elections.voting_backends.register(backend_name) do |manifest|
              manifest.live_tally = live_tally
              manifest.applies_to { |e| e.id == election.id }
            end
          end

          after do
            Decidim::Elections.voting_backends.manifests.reject! { |m| m.name == backend_name }
          end

          context "when live_tally is false and question results are not published (per_question)" do
            before do
              register_backend(live_tally: false)
              get dashboard_path, headers:
            end

            it "shows the hidden-results note instead of the results table" do
              expect(response).to have_http_status(:ok)
              expect(response.body).to include(
                I18n.t("decidim.elections.admin.dashboard.questions_table.hidden_until_published")
              )
              expect(response.body).not_to include("table-list")
            end
          end

          context "when live_tally is false and question results are published (per_question)" do
            before do
              question.update!(voting_enabled_at: Time.current, published_results_at: Time.current)
              register_backend(live_tally: false)
              get dashboard_path, headers:
            end

            it "shows the results table once results are published" do
              expect(response).to have_http_status(:ok)
              expect(response.body).to include("table-list")
              expect(response.body).not_to include(
                I18n.t("decidim.elections.admin.dashboard.questions_table.hidden_until_published")
              )
            end
          end

          context "when live_tally is true" do
            before do
              register_backend(live_tally: true)
              get dashboard_path, headers:
            end

            it "shows the results table even without published results" do
              expect(response).to have_http_status(:ok)
              expect(response.body).to include("table-list")
              expect(response.body).not_to include(
                I18n.t("decidim.elections.admin.dashboard.questions_table.hidden_until_published")
              )
            end
          end

          context "when the election is not per_question and results are not published" do
            let!(:election) { create(:election, :published, :ongoing, :with_token_csv_census, component:) }

            before do
              register_backend(live_tally: false)
              get dashboard_path, headers:
            end

            it "uses election.published_results? to decide visibility" do
              expect(response).to have_http_status(:ok)
              expect(response.body).to include(
                I18n.t("decidim.elections.admin.dashboard.questions_table.hidden_until_published")
              )
            end
          end
        end

        # The calendar's "Results published at" shows election.results_at.
        describe "calendar results_at" do
          let!(:election) { create(:election, :published_results, :with_token_csv_census, component:) }

          before { get dashboard_path, headers: }

          it "shows the published_results_at label and formatted date" do
            expect(response).to have_http_status(:ok)
            expect(response.body).to include(
              I18n.t("decidim.elections.admin.dashboard.calendar.published_results_at")
            )
            expect(response.body).to include(
              I18n.l(election.results_at, format: :decidim_short)
            )
          end
        end
      end
    end
  end
end
