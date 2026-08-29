# frozen_string_literal: true

# A module reading a table it does not own.
#
# Its own controller rather than an action on the queue, because it asks for a
# different permission and a page that inherits one it does not need is a link
# somebody can see and cannot open. `test/navigation_test.rb` caught exactly
# that: the menu entry asked for `core.audit.read` while the page it led to
# also required `core.modules.read`.
#
# The trail existed and had no page. Reaching it meant curl and an admin token,
# which makes "who read what" a question nobody asks.
class AuditTrailController < ApplicationController
  requires "core.audit.read"

  def index
    @report = database.audit(module_name: params[:module_name].presence,
                             refusals: params[:refusals].presence)
    @events = Array(@report && @report["events"])
    @module_name = params[:module_name].presence
    @refusals = params[:refusals] == "true"
  end

  private

  def database
    @database ||= Siberian::DatabaseClient.new(logger: Rails.logger)
  end
end
