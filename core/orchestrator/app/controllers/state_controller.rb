# frozen_string_literal: true

# Converging everything that is derived from the database rather than held in
# it: routing, what the other core services know, and the permission catalogue.
#
# Separate from RoutesController because the two answer different questions.
# "Routing is broken, fix it" is a repair an operator reaches for knowingly.
# This is the sweep that also tells them what it would not fix.
class StateController < ApplicationController
  requires "core.modules.read"

  def reconcile
    result = Reconciler.new.call

    redirect_to modules_path, **flash_for(result)
  end

  private

  # Three outcomes worth telling apart. Everything converged, everything
  # converged but something needs a hand, or a step could not run at all.
  def flash_for(result)
    return { alert: "Reconcile incomplete: #{result.errors.join('; ')}" } unless result.ok?

    if result.drifted.any?
      { alert: "Reconciled #{result.changed.length} item(s). Needs attention: #{result.drifted.join('; ')}" }
    elsif result.changed.any?
      { notice: "Reconciled #{result.changed.length} item(s): #{result.changed.take(4).join(', ')}" \
                "#{', and more' if result.changed.length > 4}." }
    else
      { notice: "Everything already matches: nothing to reconcile." }
    end
  end
end
