# frozen_string_literal: true

class HomeController < ApplicationController
  def show
    @groups = directory.grouped(domain: current_domain, only: method(:visible_capabilities))
    @capabilities = @groups.flat_map(&:last)
  end
end
