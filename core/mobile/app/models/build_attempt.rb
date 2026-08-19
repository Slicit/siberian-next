# frozen_string_literal: true

# One attempt at one build.
#
# Kept separately from the build so a build that succeeded on the third try
# still says what happened on the first two, which is usually the interesting
# part.
class BuildAttempt < ApplicationRecord
  belongs_to :build

  validates :number, presence: true, uniqueness: { scope: :build_id }
  validates :outcome, presence: true
  validates :attempted_at, presence: true
end
