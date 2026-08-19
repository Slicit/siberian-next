# frozen_string_literal: true

# What answers each core interface, and in what order.
#
# This is the page an operator opens when mail stops arriving, so it shows the
# whole chain rather than only the winner.
class InterfacesController < ApplicationController
  requires "core.modules.read"
  def index
    registry = InterfaceRegistry.new
    @interfaces = registry.known_interfaces.map do |interface|
      { name: interface, implementations: registry.implementations(interface) }
    end
  end
end
