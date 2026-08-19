# frozen_string_literal: true

class ActivitiesController < ApplicationController
  requires "core.audit.read"
  def index
    @activities = Activity.recent.includes(:installed_module).limit(200)
  end
end
