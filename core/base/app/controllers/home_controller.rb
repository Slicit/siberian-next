# frozen_string_literal: true

class HomeController < ApplicationController
  def show
    @groups = directory.grouped(domain: current_domain)
    @capabilities = @groups.flat_map(&:last)
  end
end
