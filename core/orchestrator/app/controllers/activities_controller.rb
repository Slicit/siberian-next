# frozen_string_literal: true

class ActivitiesController < ApplicationController
  def index
    @activities = Activity.recent.includes(:installed_module).limit(200)
  end
end
