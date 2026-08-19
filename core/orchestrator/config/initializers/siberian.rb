# frozen_string_literal: true

# Loads the shared library from wherever it is: /app/lib inside a container,
# or ../../lib when running from the monorepo. Explicit require rather than
# autoload, because these files define Siberian::* and Zeitwerk would expect
# names derived from their paths.
shared_lib = [
  Rails.root.join("lib"),
  Rails.root.join("..", "..", "lib")
].find { |path| File.exist?(File.join(path.to_s, "contracts.rb")) }

if shared_lib
  $LOAD_PATH.unshift(File.expand_path(shared_lib.to_s))
  require "contracts"
else
  Rails.logger&.warn("Shared lib/ not found. Manifest parsing and the engine driver are unavailable.")
end
