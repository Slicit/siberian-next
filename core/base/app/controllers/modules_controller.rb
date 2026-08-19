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

    # Checked here as well as in the sidebar. A hidden link is not access
    # control; somebody can always type the URL.
    unless allow?("module.#{@capability.module_name}.use")
      @missing_permission = "module.#{@capability.module_name}.use"
      return render "shared/no_access", status: :forbidden
    end

    @groups = directory.grouped(domain: current_domain, only: method(:visible_capabilities))

    # A module page can be deep-linked: /m/<capability>/notes/42 renders the
    # module at /notes/42 rather than at its front door.
    @frame_url = @capability.url.to_s
    @frame_url += "/#{params[:rest]}" if params[:rest].present?
  end
end
