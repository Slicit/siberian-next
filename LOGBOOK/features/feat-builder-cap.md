---
status: shipped
branch: fix-build-failures
---

# The builder's CPU cap, measured

## Intent

The builder is capped at one core of two so that a build cannot starve Postgres.
Whether one is the right number had been an open question for a while, and the
argument for raising it was a figure that turned out to be wrong.

## Decisions

### 2026-08-30: the number that motivated this was a guess

`feat-app-themes.md` recorded that the cap took Android builds from about ten
minutes to "over thirty five". It does not, and never did: the recorded
durations of the last twelve successful builds are 18 to 25 minutes, read from
`build_attempts.duration_ms`.

The original came from noticing a build still running some time after it started
and assuming the rest. It is corrected where it was written rather than quietly,
because it was the whole argument for changing the cap.

### 2026-08-30: measured on both sides, because build time is only half of it

The question is not "are builds faster with more CPU", which has an obvious
answer. It is whether the product stays responsive, because that is what the cap
was set to protect.

Three pages, eight samples each, taken while an Android build was actually
running.

| | one core | one and a half |
|---|---|---|
| Android build | 19.6 min (19.4, 19.7, 19.7) | 14.2 min |
| builder CPU observed | 105% | 149% |
| `core/modules` | 103 ms | 132 ms |
| the product root | 53 ms | 67 ms |
| a module page | 92 ms | 115 ms |

Builds are 27 percent faster. Pages are 25 to 28 percent slower and still under
135 milliseconds, which is not a number anybody notices.

### 2026-08-30: the compose default stays at one, the box runs at one and a half

Those are different decisions and it is worth being clear about which is which.

`SIBERIAN_BUILDER_CPUS` defaults to `1.0` in compose, unchanged, because that is
what anybody else's deployment inherits and half a core for eleven services is
not a default to hand out on the strength of one box's numbers. The comment
there is still right: a build nobody is watching should lose to a page somebody
is.

This box's `.env` sets `1.5`, because the measurement was taken here and says it
is a good trade here: one operator, builds several times an hour, and latency
that stays comfortably under what anybody would notice. One line in `.env` puts
it back.

What the measurement cannot say is how this behaves with several people using
the product at once. Every number above was taken with one caller, and half a
core for the whole rest of the system is the sort of margin that looks fine
until it does not.

## Outcome

The question is answered with numbers rather than a guess, on both sides of the
trade, and the two decisions it implies are separated: what everybody gets, and
what this box does.
