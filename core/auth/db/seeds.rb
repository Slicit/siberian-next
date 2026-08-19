# frozen_string_literal: true

# Demo credentials and the roles a fresh installation needs to be usable.
#
# Deliberately obvious rather than clever: these exist so somebody can open the
# app and look around, and a password nobody can guess from the README is a
# password nobody can use.
if Rails.env.production? && ENV["SIBERIAN_ALLOW_DEMO_SEEDS"] != "true"
  warn "Refusing to seed demo accounts in production. Set SIBERIAN_ALLOW_DEMO_SEEDS=true to override."
  exit 0
end

Role.seed_defaults!
puts "Roles: #{Role.ordered.pluck(:name).join(', ')}"

DEMO_PASSWORD = ENV.fetch("SIBERIAN_DEMO_PASSWORD", "siberian-demo")

[
  { email: "owner@siberian.localhost",    name: "Olive Owner",      role: "owner" },
  { email: "operator@siberian.localhost", name: "Ophelia Operator", role: "operator" },
  { email: "user@siberian.localhost",     name: "Ursula User",      role: "member" }
].each do |attributes|
  role = Role.find_by(name: attributes[:role])
  user = User.find_or_initialize_by(email: attributes[:email])
  user.assign_attributes(name: attributes[:name], password: DEMO_PASSWORD, active: true)
  user.save!
  user.role_assignments.find_or_create_by!(role: role)

  puts "  #{user.email.ljust(32)} #{role.name}"
end

puts "Demo password: #{DEMO_PASSWORD}"
