# frozen_string_literal: true

# This migration comes from decidim_forms (originally 20260727181138)
class AddCounterCacheToDecidimFormsQuestionnaire < ActiveRecord::Migration[8.1]
  def change
    add_column :decidim_forms_questionnaires, :responses_count, :integer, null: false, default: 0
  end
end
