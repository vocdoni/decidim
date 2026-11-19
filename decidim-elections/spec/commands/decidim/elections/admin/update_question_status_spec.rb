# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Admin
      describe UpdateQuestionStatus do
        subject { described_class.new(action, question) }

        let(:election) { create(:election, :per_question, :ongoing) }
        let(:question) { create(:election_question, election:) }
        let(:action) { :enable_voting }

        context "when action is invalid" do
          let(:action) { :invalid_action }

          it "broadcasts :invalid" do
            expect { subject.call }.to broadcast(:invalid)
          end
        end

        context "when enabling voting" do
          it "sets start_at and broadcasts :ok" do
            expect { subject.call }.to broadcast(:ok)
            expect(question.reload.voting_enabled_at).to be_present
          end
        end

        context "when publishing results" do
          let(:action) { :publish_results }

          before { question.update!(voting_enabled_at: Time.current) }

          it "sets published_results_at" do
            expect { subject.call }.to broadcast(:ok)
            expect(question.reload.published_results_at).to be_present
          end
        end

        describe "no-op guard" do
          context "when enable_voting is submitted but voting is already enabled" do
            before { question.update!(voting_enabled_at: Time.current) }

            it "broadcasts :ok without saving" do
              expect(ActiveSupport::Notifications).not_to receive(:publish)
              expect(question).not_to receive(:save!)
              expect { subject.call }.to broadcast(:ok)
            end
          end

          context "when publish_results is submitted but results are already published" do
            let(:action) { :publish_results }

            before do
              question.update!(voting_enabled_at: Time.current, published_results_at: Time.current)
            end

            it "broadcasts :ok without saving" do
              expect(ActiveSupport::Notifications).not_to receive(:publish)
              expect(question).not_to receive(:save!)
              expect { subject.call }.to broadcast(:ok)
            end
          end
        end

        describe "invalid publish guard" do
          context "when publishing results of a question whose voting was never enabled" do
            let(:action) { :publish_results }

            it "broadcasts :invalid" do
              expect { subject.call }.to broadcast(:invalid)
            end

            it "does not set published_results_at" do
              subject.call
              expect(question.reload.published_results_at).to be_nil
            end
          end
        end

        describe "publishing the last question of a per_question election" do
          let(:action) { :publish_results }

          context "when this is the last question to publish in a per_question election" do
            before { question.update!(voting_enabled_at: Time.current) }

            it "sets election.published_results_at" do
              expect { subject.call }.to broadcast(:ok)
              expect(question.election.reload.published_results_at).to be_present
            end
          end

          context "when other questions in the election still have unpublished results" do
            let!(:other_question) { create(:election_question, :voting_enabled, election:) }

            before { question.update!(voting_enabled_at: Time.current) }

            it "does not set election.published_results_at" do
              subject.call
              expect(question.election.reload.published_results_at).to be_nil
            end
          end

          context "when election already has published_results_at set" do
            before do
              question.update!(voting_enabled_at: Time.current)
              election.update!(published_results_at: 1.hour.ago)
            end

            it "does not overwrite election.published_results_at" do
              original = election.published_results_at
              subject.call
              expect(election.reload.published_results_at).to eq(original)
            end
          end

          context "when the election is not per_question" do
            let(:election) { create(:election, :real_time, :ongoing) }

            before { question.update!(voting_enabled_at: Time.current) }

            it "does not set election.published_results_at" do
              subject.call
              expect(question.election.reload.published_results_at).to be_nil
            end
          end
        end
      end
    end
  end
end
