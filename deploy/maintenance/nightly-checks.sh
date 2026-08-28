#!/usr/bin/env bash
# Runs everything that can say whether the system still works, once a night.
#
# The smokes are the only tests that cover the seams between Rails, nginx,
# Postgres, and the engine, and every expensive bug in this project has lived in
# one of those seams. They also only ran when somebody remembered to run them.
#
# That gap was not theoretical. GitHub Actions was red on every push for eight
# days because a test double had not grown a method the installer started
# calling, and nobody noticed, so every change in that window landed on a
# baseline nobody had verified.
#
# So this runs unattended and writes two things: a log for a person, and a JSON
# file the Backoffice reads so the answer is on a page somebody already looks at
# rather than in a file somebody has to know about.
set -uo pipefail

REPO="${SIBERIAN_REPO:-/home/claude/siberian-next}"
RESULTS_DIR="${SIBERIAN_CHECK_RESULTS:-$REPO/deploy/checks}"
RESULTS="$RESULTS_DIR/latest.json"
TIMEOUT="${CHECK_TIMEOUT:-600}"

cd "$REPO" || { echo "no repo at $REPO"; exit 1; }

say() { printf '%s  %s\n' "$(date -Is)" "$*"; }

started_at="$(date -Is)"
run_started=$SECONDS
entries=""
failures=0
total=0

# Runs one check and records how it went. Never exits on failure: the point is
# a complete picture, and stopping at the first red would hide everything after
# it, which is exactly the situation this exists to end.
record() { # record <name> <command...>
  local name="$1"; shift
  local began=$SECONDS
  local status="ok"
  local detail=""

  total=$((total + 1))
  say "running $name"

  if ! detail="$(timeout "$TIMEOUT" "$@" 2>&1)"; then
    status="failed"
    failures=$((failures + 1))
    say "  $name FAILED"
  fi

  local seconds=$((SECONDS - began))

  # The last few lines only. A failing smoke prints the step it got to, which
  # is the useful part; the whole transcript belongs in the log, not in a field
  # the Backoffice renders.
  local tail_text
  tail_text="$(printf '%s' "$detail" | tail -4)"

  printf '%s\n' "$detail" | sed 's/^/    /'

  entries="${entries}${entries:+,}$(json_entry "$name" "$status" "$seconds" "$tail_text")"
}

# Hand rolled rather than jq, which is not installed on the box and would be a
# dependency for one object a night.
json_escape() {
  printf '%s' "$1" \
    | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g; s/\r//g' \
    | awk 'BEGIN{ORS=""} {print sep $0; sep="\\n"}'
}

json_entry() { # <name> <status> <seconds> <detail>
  printf '{"name":"%s","status":"%s","seconds":%s,"detail":"%s"}' \
    "$(json_escape "$1")" "$(json_escape "$2")" "$3" "$(json_escape "$4")"
}

say "starting the nightly sweep in $REPO"

record "check" ./bin/check
record "test-lib" ./bin/test-lib
# Asks whether every class the application names can actually be loaded, and
# whether the whole thing would boot the way a deployment configures it. The box
# runs in development mode on purpose, so nothing else ever exercises either.
record "check-boot" ./bin/check-boot

for smoke in bin/smoke-*; do
  case "$smoke" in
    *.sh) continue ;;
  esac
  [ -x "$smoke" ] || continue
  record "$(basename "$smoke")" "./$smoke"
done

duration=$((SECONDS - run_started))

mkdir -p "$RESULTS_DIR"
# Written whole to a temporary file and moved into place, so the Backoffice
# never reads a half written file and reports nonsense.
tmp="$(mktemp)"
cat > "$tmp" <<JSON
{
  "ran_at": "$started_at",
  "duration_seconds": $duration,
  "total": $total,
  "failures": $failures,
  "checks": [$entries]
}
JSON
mv "$tmp" "$RESULTS"
chmod 0644 "$RESULTS"

say "finished: $((total - failures))/$total passed in ${duration}s"
[ "$failures" -eq 0 ] || say "FAILURES: $failures. See above, and $RESULTS."

# Zero even when checks failed. The result is the report, and a cron job that
# exits non-zero only adds a second, less informative alarm in the mail spool.
exit 0
