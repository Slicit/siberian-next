# frozen_string_literal: true

# Renders one module capability inside the shell.
#
# The module lives at its own origin and gets an iframe. It shares no CSS, no
# JavaScript, and no DOM with the shell, and the browser enforces that rather
# than a convention: nothing a module does to its own page can reach out here.
class ModulesController < ApplicationController
  def show
    @capability = directory.find(domain: current_domain, id: params[:id])
    return redirect_to root_path, alert: "That feature is not installed." if @capability.nil?

    @groups = directory.grouped(domain: current_domain)

    # A module page can be deep-linked: /m/<capability>/notes/42 renders the
    # module at /notes/42 rather than at its front door.
    @frame_url = @capability.url.to_s
    @frame_url += "/#{params[:rest]}" if params[:rest].present?
  end
end
