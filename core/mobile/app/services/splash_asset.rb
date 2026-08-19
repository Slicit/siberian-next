# frozen_string_literal: true

# Checks a splash asset before it becomes somebody's first impression of an app.
#
# Done here rather than in the builder because a build takes minutes and this
# takes microseconds: an image that cannot work should be refused while the
# person who chose it is still looking at the screen, not twenty minutes later
# in a Gradle log.
class SplashAsset
  # The square the artwork is authored at. Anything square scales, so a smaller
  # square is a warning rather than a refusal, but below this it is being
  # enlarged on every phone that matters.
  RECOMMENDED = 2500
  MINIMUM = 512
  MAX_BYTES = 8 * 1024 * 1024

  # Android masks the system splash icon to a circle of roughly two thirds of
  # the canvas. Everything outside that is decoration that some devices crop,
  # so it is where padding goes and not where a logo goes.
  SAFE_FRACTION = 0.66

  Result = Struct.new(:ok, :width, :height, :problems, :warnings, keyword_init: true) do
    def ok? = ok == true
  end

  def self.safe_zone_px(size = RECOMMENDED) = (size * SAFE_FRACTION).round

  # PNG only, and the dimensions are read from the header rather than by
  # decoding: the first 24 bytes of a PNG carry width and height, so knowing
  # them costs nothing and needs no image library in a service that has no
  # other reason to carry one.
  def self.inspect_image(bytes)
    problems = []
    warnings = []

    return refusal("the file is empty") if bytes.nil? || bytes.empty?
    return refusal("the image is larger than #{MAX_BYTES / 1024 / 1024} MB") if bytes.bytesize > MAX_BYTES

    signature = bytes.byteslice(0, 8)
    return refusal("that is not a PNG. Splash artwork has to be a PNG, because it needs transparency and no compression artefacts") unless signature == "\x89PNG\r\n\x1a\n".b

    header = bytes.byteslice(12, 4)
    return refusal("the PNG has no header chunk where one has to be") unless header == "IHDR"

    width, height = bytes.byteslice(16, 8).unpack("N2")

    problems << "the image is #{width} by #{height}. It has to be square, because it is centred on screens of every shape" if width != height
    problems << "the image is #{width} pixels square, which is below the #{MINIMUM} minimum" if width == height && width < MINIMUM

    if problems.empty? && width != RECOMMENDED
      warnings << "authored at #{width} square rather than #{RECOMMENDED}. It will still work; #{RECOMMENDED} is the size that never has to be enlarged."
    end

    if problems.empty?
      warnings << "keep the logo inside the centre #{safe_zone_px(width)} pixels. Android masks the splash icon to a circle and crops the rest."
    end

    Result.new(ok: problems.empty?, width: width, height: height, problems: problems, warnings: warnings)
  end

  # Android animates a splash through the platform splash screen API, and the
  # only thing that API animates is an AnimatedVectorDrawable. Not a GIF, not a
  # video, not a sequence of PNGs. Sniffing for the root element is enough to
  # refuse the three things people try first.
  def self.inspect_animation(bytes)
    return refusal("the file is empty") if bytes.nil? || bytes.empty?
    return refusal("the animation is larger than #{MAX_BYTES / 1024 / 1024} MB") if bytes.bytesize > MAX_BYTES

    head = bytes.byteslice(0, 4096).to_s

    if head.start_with?("GIF8")
      return refusal("that is a GIF. Android animates a splash from an AnimatedVectorDrawable, which is XML, and cannot play a GIF there")
    end

    unless head.include?("<animated-vector")
      return refusal("that is not an AnimatedVectorDrawable. It has to be XML with an <animated-vector> root, which is the only thing Android's splash screen animates")
    end

    Result.new(ok: true, width: nil, height: nil, problems: [],
               warnings: ["Android stops the splash animation after one second whatever the drawable says."])
  end

  def self.refusal(message)
    Result.new(ok: false, problems: [message], warnings: [])
  end
  private_class_method :refusal
end
