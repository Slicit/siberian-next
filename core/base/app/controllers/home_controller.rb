# frozen_string_literal: true

class HomeController < ApplicationController
  def show
    # @groups is loaded for every page by ApplicationController.
    @capabilities = @groups.flat_map(&:last)
  end
end
