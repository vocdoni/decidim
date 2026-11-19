# frozen_string_literal: true

# This migration comes from decidim_budgets (originally 20260724121617)
class AddProjectsCountToDecidimBudgetsBudgets < ActiveRecord::Migration[8.1]
  def change
    add_column :decidim_budgets_budgets, :projects_count, :integer, null: false, default: 0
  end
end
