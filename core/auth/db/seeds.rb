# frozen_string_literal: true

# Demo credentials. Deliberately obvious rather than clever: these exist so
# somebody can open the app and look around, and a password nobody can guess
# from the README is a password nobody can use.
#
# Guarded so a real deployment cannot seed itself by accident.
if Rails.env.production? && ENV["SIBERIAN_ALLOW_DEMO_SEEDS"] != "true"
  warn "Refusing to seed demo accounts in production. Set SIBERIAN_ALLOW_DEMO_SEEDS=true to override."
  exit 0
end

DEMO_PASSWORD = ENV.fetch("SIBERIAN_DEMO_PASSWORD", "siberian-demo")

[
  { email: "operator@siberian.localhost", name: "Ophelia Operator", operator: true },
  { email: "user@siberian.localhost",     name: "Ursula User",      operator: false }
].each do |attributes|
  user = User.find_or_initialize_by(email: attributes[:email])
  user.assign_attributes(attributes.merge(password: DEMO_PASSWORD))
  user.save!
  puts "  #{user.email.ljust(32)} #{user.operator? ? 'operator' : 'user'}"
end

puts "Demo password: #{DEMO_PASSWORD}"
