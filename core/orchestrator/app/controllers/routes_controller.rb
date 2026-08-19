# frozen_string_literal: true

# Repairing routing after the Router container has been replaced.
#
# A rebuilt Router is a new container, so its attachments to every module
# network are gone and every module route answers 502 with nothing in any log
# to explain it. One button beats an explanation.
class RoutesController < ApplicationController
  requires "core.modules.read"
  def reconcile
    result = RouteReconciler.new.call

    if result.ok?
      redirect_to modules_path,
                  notice: "Routing repaired: #{result.joined.length} network(s) rejoined, " \
                          "#{result.written.length} module(s) rewritten."
    else
      redirect_to modules_path, alert: "Routing partly repaired: #{result.errors.join('; ')}"
    end
  end
end
