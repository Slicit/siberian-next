# frozen_string_literal: true

# Answers "who implements this interface?" for the core.
#
# The core never names a module. It asks for mail.transport.v1 and gets back
# somewhere to send the request, which is the whole point of a system
# capability: mail can be answered by a module without the mailer knowing that
# a module exists.
class InterfaceRegistry
  # The core's built-in services are the fallback, registered at a priority no
  # module reaches by accident.
  BUILT_IN = {
    "mail.transport.v1" => "http://mailer:3000/internal/mail",
    "auth.provider.v1" => "http://auth:3000/internal/auth",
    "storage.files.v1" => "http://storage:3000/v1"
  }.freeze

  Implementation = Struct.new(:interface, :url, :provider, :priority, :built_in, keyword_init: true) do
    def built_in? = built_in == true
    def to_s = "#{interface} -> #{url}#{built_in? ? ' (core)' : " (#{provider})"}"
  end

  # Best first: a module that declared a lower priority wins, and the core's own
  # service is the last resort rather than the first choice. A module that wants
  # to sit behind the core can say so with a priority above CORE_PRIORITY.
  def implementations(interface)
    from_modules = Capability.implementing(interface).includes(:installed_module).filter_map do |capability|
      next unless capability.installed_module.live?

      Implementation.new(
        interface: interface,
        url: capability.internal_url,
        provider: capability.installed_module.name,
        priority: capability.priority,
        built_in: false
      )
    end

    if BUILT_IN.key?(interface)
      from_modules << Implementation.new(
        interface: interface,
        url: BUILT_IN.fetch(interface),
        provider: "core",
        priority: Capability::CORE_PRIORITY,
        built_in: true
      )
    end

    from_modules.sort_by { |implementation| [implementation.priority, implementation.built_in? ? 1 : 0] }
  end

  # What the core should actually call. Nil means nothing implements it and the
  # core has no built-in answer either, which is a real answer: the feature is
  # simply not available.
  def resolve(interface)
    implementations(interface).first
  end

  # Every interface anything currently answers, for the Backoffice to show.
  def known_interfaces
    (BUILT_IN.keys + Capability.system.distinct.pluck(:interface)).compact.uniq.sort
  end
end
