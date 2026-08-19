# frozen_string_literal: true

# The module contract: what a module declares, and what the core does with it.
#
# Container specs are engine-neutral values from siberian_engine, so parsing a
# manifest never produces anything a Kubernetes backend could not honour.
require_relative "siberian_engine"
require_relative "contracts/manifest"
require_relative "permissions"

module Siberian
  module Contracts
    SCHEMA_VERSION = 1
  end
end
