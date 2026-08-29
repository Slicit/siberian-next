# frozen_string_literal: true

# A name for a person that never changes and is never given to anybody else.
#
# Modules key their own rows by whatever the core hands them, so what the core
# hands them decides what happens when somebody changes their address or ends
# their account. An address is how somebody signs in; it was never meant to be
# who they are.
#
# The prefix is not decoration. `users` and `app_users` are separate tables with
# separate sequences, so operator 7 and app user 7 both exist, and a module
# keying by a bare id would mix their rows together. Two prefixes make that
# impossible, and make a value self-describing wherever it turns up: in a
# module's table, in a log line, in a support question about whose row this is.
module StableSubject
  extend ActiveSupport::Concern

  included do
    before_validation :assign_subject, on: :create
    validates :subject, presence: true, uniqueness: true
  end

  class_methods do
    # Declared by each model rather than derived from the table name, so that
    # renaming a table cannot silently renumber everybody.
    def subject_prefix(prefix = nil)
      @subject_prefix = prefix if prefix
      @subject_prefix
    end

    def new_subject = "#{subject_prefix}_#{SecureRandom.uuid.delete("-")}"
  end

  private

  # Kept if one is already set, so a record restored from a backup or moved
  # between deployments keeps the name every module knows it by.
  def assign_subject
    self.subject = self.class.new_subject if subject.blank?
  end
end
