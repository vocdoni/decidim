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
