# frozen_string_literal: true

require "anthropic"

# Turns a description of an app into a proposed configuration.
#
# It proposes. It does not apply anything: the return value is a suggestion a
# person accepts or rejects, capability by capability. That is the same rule
# that governs a manifest here, for the same reason. A manifest is written by a
# third party and an operator caps it; a proposal is written by a model and a
# person caps it. Neither gets to switch on a capability that lets an app follow
# somebody between apps or take their money.
class AppAdvisor
  class NotConfigured < StandardError; end
  class Refused < StandardError; end

  MODEL = :"claude-opus-5"
  TOOL = "propose_app_configuration"

  def self.available? = ENV["ANTHROPIC_API_KEY"].to_s.strip.present?

  def initialize(api_key: ENV["ANTHROPIC_API_KEY"])
    raise NotConfigured, "no ANTHROPIC_API_KEY is set for the Mobile service" if api_key.to_s.strip.empty?

    @client = Anthropic::Client.new(api_key: api_key)
  end

  # `app` is the app as it stands, so the model revises rather than starts over
  # when somebody asks for a change to something that already exists.
  def call(description:, domain:, app: nil, modules: [])
    message = @client.messages.create(
      model: MODEL,
      max_tokens: 8_000,
      thinking: { type: "adaptive" },
      system_: [{ type: "text", text: system_prompt }],
      tools: [tool_definition],
      # One call, one proposal. Nothing here needs a loop: the model is reading
      # a description and answering with a shape, not doing work.
      tool_choice: { type: "tool", name: TOOL },
      messages: [{ role: "user", content: user_prompt(description, domain, app, modules) }]
    )

    if message.stop_reason == :refusal
      raise Refused, message.stop_details&.explanation.presence || "the model declined to answer"
    end

    block = message.content.find { |content| content.type == :tool_use }
    raise Refused, "the model answered without a proposal" if block.nil?

    normalise(block.input)
  end

  private

  def system_prompt
    <<~PROMPT
      You configure a phone app for one domain of a modular application platform.
      Somebody describes what the app is for; you propose a configuration.

      You are proposing, not deciding. Everything you return is shown to a person
      who accepts or rejects it capability by capability, so say what you would do
      and why, and do not soften a recommendation to make it easier to accept.

      The native capabilities you may propose are exactly these, and no others:

      #{catalogue_for_prompt}

      How to choose:

      - Propose a capability when the description implies the app cannot work
        without it. Not because it might be nice later: every capability is
        something the app can then do to somebody, and an app that asks for
        five permissions on first launch is an app people refuse.
      - The ones marked "asks a lot" need a reason drawn from the description
        itself. If the description does not call for tracking or payments, do
        not propose them, and say so if the person seems to expect them.
      - A capability with settings needs those values from a person. Propose it
        if it is genuinely needed, and say in the reason that it will not work
        until the keys are supplied.
      - Say when you are unsure rather than guessing. "This might need location
        if deliveries are tracked live" is more useful than a confident wrong
        answer.

      The bundle identifier is the identity of the app in both stores and cannot
      be changed after a release without shipping a different app. Derive it from
      the domain unless the description gives a better reason.
    PROMPT
  end

  def catalogue_for_prompt
    Siberian::MobileCapabilities::CATALOGUE.map do |capability|
      line = "- #{capability[:id]} (#{capability[:package]}): #{capability[:summary]}"
      line += " ASKS A LOT." if capability[:severity] == :high
      line += " Needs settings: #{capability[:settings].map { |s| s[:key] }.join(', ')}." if capability[:settings].any?
      line
    end.join("\n")
  end

  def user_prompt(description, domain, app, modules)
    parts = ["The domain is #{domain}."]

    if app
      parts << "The app already exists: name #{app['name']}, bundle identifier " \
               "#{app['bundle_identifier']}, version #{app['version']}. " \
               "Capabilities already on: #{Array(app['capabilities']).select { |c| c['enabled'] }.map { |c| c['capability'] }.join(', ').presence || 'none'}."
    else
      parts << "No app has been configured for this domain yet."
    end

    if modules.any?
      parts << "The modules installed on this domain are: #{modules.join(', ')}. " \
               "A module that ships native code may require capabilities of its own; " \
               "those are approved separately and are not your decision."
    end

    parts << "Here is what it is for, in their words:\n\n#{description}"
    parts.join("\n\n")
  end

  def tool_definition
    {
      name: TOOL,
      description: "Propose a configuration for the domain's phone app. Everything proposed is reviewed by a person before it takes effect.",
      input_schema: {
        type: "object",
        additionalProperties: false,
        required: %w[name bundle_identifier capabilities summary],
        properties: {
          name: { type: "string", description: "What somebody sees under the icon. Short." },
          bundle_identifier: {
            type: "string",
            description: "Reverse domain form, for example test.siberian. Lowercase, at least two segments."
          },
          primary_color: { type: "string", description: "Hex colour such as #2563eb, or omit if the description gives no reason to choose one." },
          capabilities: {
            type: "array",
            description: "Only capabilities the description calls for. An empty list is a valid answer.",
            items: {
              type: "object",
              additionalProperties: false,
              required: %w[id reason],
              properties: {
                id: { type: "string", enum: Siberian::MobileCapabilities::IDS },
                reason: { type: "string", description: "Why this app needs it, drawn from the description." }
              }
            }
          },
          summary: { type: "string", description: "A sentence or two for the person reviewing this, including anything you were unsure about." }
        }
      },
      strict: true
    }
  end

  # The model answers in the shape the schema asked for, and this still checks:
  # a capability that is not in the catalogue is dropped rather than passed on to
  # something that would have to decide what to do with it.
  def normalise(input)
    proposal = input.deep_dup.with_indifferent_access

    proposal[:capabilities] = Array(proposal[:capabilities]).select do |capability|
      Siberian::MobileCapabilities.known?(capability[:id])
    end.map do |capability|
      definition = Siberian::MobileCapabilities.find(capability[:id])
      capability.merge(
        label: definition[:label],
        package: definition[:package],
        severity: definition[:severity],
        settings: definition[:settings]
      )
    end

    proposal
  end
end
