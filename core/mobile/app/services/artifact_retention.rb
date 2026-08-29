# frozen_string_literal: true

# Removes build artifacts that nothing needs any more.
#
# A build leaves an APK of sixty megabytes and nothing ever took one away, so
# forty-one builds of the same app held two gigabytes on a box with five free.
# The disk filling is not a storage problem to be solved with more storage: a
# superseded build of an app that has been built eleven times since is not
# something anybody is going to install.
#
# What is kept is the newest artifact per app and platform, because that is the
# one somebody might install right now. What is deleted is the binary only. The
# build row, its log, its duration and its outcome all stay: those are how a
# failure six weeks ago is explained, they cost bytes rather than megabytes, and
# losing them to reclaim space nobody was short of would be a bad trade.
#
# `artifact_path` is cleared as the record that the binary is gone, so the
# Backoffice offers no download that answers 404.
class ArtifactRetention
  Result = Struct.new(:removed, :bytes, :kept, :errors, keyword_init: true) do
    def ok? = errors.empty?
    def megabytes = (bytes / 1048576.0).round(1)
  end

  # How many artifacts to keep per app and platform. One by default: the
  # question this answers is "can I install the current build", and the answer
  # never involves the one before it.
  def initialize(keep: ENV.fetch("SIBERIAN_KEEP_ARTIFACTS", "1").to_i,
                 storage: StorageAccess.new)
    @keep = [keep, 1].max
    @storage = storage
  end

  def call(dry_run: false)
    removed = 0
    bytes = 0
    kept = 0
    errors = []

    superseded.each do |build|
      if dry_run
        removed += 1
        bytes += build.artifact_bytes.to_i
        next
      end

      begin
        @storage.remove(domain: build.domain, path: build.artifact_path)
        bytes += build.artifact_bytes.to_i
        removed += 1
        # Cleared after the delete, not before: a record saying the binary is
        # gone while it is still occupying the disk is the one state that makes
        # the space unreclaimable, because nothing knows to look for it.
        build.update_columns(artifact_path: nil)
      rescue StandardError => e
        errors << "#{build.id}: #{e.message}"
      end
    end

    kept = keepers.length
    Result.new(removed: removed, bytes: bytes, kept: kept, errors: errors)
  end

  private

  # The newest artifacts, one set per app and platform, which are the ones to
  # leave alone.
  def keepers
    @keepers ||= with_artifacts
                 .group_by { |build| [build.mobile_app_id, build.platform] }
                 .flat_map { |_, builds| builds.sort_by(&:id).last(@keep) }
                 .map(&:id)
  end

  def superseded = with_artifacts.reject { |build| keepers.include?(build.id) }

  def with_artifacts
    @with_artifacts ||= Build.where.not(artifact_path: nil).to_a
  end
end
