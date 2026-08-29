# Shared by every bin/smoke-*.sh. Sourced, not run.
#
# A check that narrates is not a check. Several of these scripts used to print
# what they got beside what they hoped for and exit zero either way, so a run
# where the thing under test was broken looked exactly like a run where it was
# not. The nightly job records exit codes, which means a narrating smoke
# reported "OK" every night while the feature it describes was dead.
#
# Two ways to say the same thing, because the callers differ:
#
#   expect "1. the module answers" "$code" 200
#   check  "the token is refused"  "$code" 401
#
# `expect` prints the label with the value beside it, which is what the older
# scripts did and what makes their output readable as a transcript. `check`
# prints ok or FAIL against a sentence. Both count a failure the same way.
#
# Failures accumulate rather than exiting at the first one: a smoke that stops
# on step 2 hides whether steps 3 to 12 also broke, and the whole point of
# running it is to find out what the state of the system is.

SMOKE_FAILURES=0

expect() { # expect <label> <got> <wanted>
  if [ "$2" = "$3" ]; then
    echo "$1 -> $2"
  else
    echo "$1 -> $2   FAIL, wanted $3"
    SMOKE_FAILURES=$((SMOKE_FAILURES + 1))
  fi
}

check() { # check <sentence> <got> <wanted>
  if [ "$2" = "$3" ]; then
    printf '   ok    %s\n' "$1"
  else
    printf '   FAIL  %s (wanted %s, got %s)\n' "$1" "$3" "$2"
    SMOKE_FAILURES=$((SMOKE_FAILURES + 1))
  fi
}

# For the cases where the answer is "it contains this", which is most of the
# ones involving a rendered page.
contains() { # contains <sentence> <haystack> <needle>
  case "$2" in
    *"$3"*) printf '   ok    %s\n' "$1" ;;
    *)
      printf '   FAIL  %s (no "%s" in the answer)\n' "$1" "$3"
      SMOKE_FAILURES=$((SMOKE_FAILURES + 1))
      ;;
  esac
}

present() { # present <sentence> <value>
  if [ -n "$2" ]; then
    printf '   ok    %s\n' "$1"
  else
    printf '   FAIL  %s (nothing found)\n' "$1"
    SMOKE_FAILURES=$((SMOKE_FAILURES + 1))
  fi
}

# Called last. The exit code is the whole reason the nightly job can be trusted.
finish() { # finish <name>
  echo
  if [ "$SMOKE_FAILURES" -eq 0 ]; then
    echo "$1: every check passed"
    return 0
  fi

  echo "$1: $SMOKE_FAILURES check(s) FAILED"
  exit 1
}
