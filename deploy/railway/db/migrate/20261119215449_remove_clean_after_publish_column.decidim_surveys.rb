# frozen_string_literal: true

# This migration comes from decidim_surveys (originally 20260914072205)
class RemoveCleanAfterPublishColumn < ActiveRecord::Migration[8.1]
  def change
    remove_column :decidim_surveys_surveys, :clean_after_publish, :boolean
  end
end
