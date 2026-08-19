---
status: shipped
branch: feat-app-studio
---

# Configuring the phone app from the product side, with an assistant

## Intent

The Backoffice configures every domain's app because an operator runs the
system. That is the wrong place for the person who knows what the app is for.
They are inside one domain, and it is the only app they have any business
configuring.

Describing an app is also easier than configuring one. Somebody can say "our
engineers need to find the next job on a map and work in basements with no
signal" long before they can say "expo-location and expo-network". So the
product side takes a description and answers with a proposal.

Out of scope for this feature:

- The assistant applying anything. It proposes; a person accepts, capability by
  capability.
- Supplying a capability's settings from here. A RevenueCat key is an operator's
  business and stays in the Backoffice.
- Anything about the build itself. This queues one the same way the Backoffice
  does.

## Plan

1. ~~The Mobile client moves to `lib/`, because two interfaces now ask the same service the same questions.~~
2. ~~An advisor in the Mobile service: a description in, a proposal out, nothing written.~~
3. ~~A page on the product side, scoped to the domain on the request.~~
4. ~~Accepting a proposal is a separate action, with a tickbox per capability.~~

## Decisions

### 2026-08-19

- **Decision:** the assistant proposes and never applies.
- **Why:** this is the rule the whole system already runs on. A manifest is written by a third party and an operator caps it. A proposal is written by a model and a person caps it. Two of these capabilities let an app follow somebody between apps or take their money, and neither should ever arrive because something inferred it from a sentence.
- **Impact:** the proposal renders as a form with one tickbox per capability and the reason next to it. What is applied is what was ticked, and the model's answer is never the thing that writes.

- **Decision:** the page is scoped to the domain the Router put on the request, not to a domain in a parameter.
- **Why:** the product shell is per domain and the Backoffice is cross-domain. A page here that took a domain as input would be a second Backoffice with weaker checks, which is the sort of thing nobody notices until it matters.
- **Impact:** `PhoneAppController` passes `current_domain` and nothing else. There is no route that names a domain.

- **Decision:** it needs `core.mobile.manage`, the same permission the Backoffice page uses.
- **Why:** switching on a native capability is the same act wherever it is done. Inventing a second permission for the product side would mean two answers to one question.
- **Impact:** somebody who can use the product still cannot decide what the app may do to a phone. The nav entry is not rendered for them.

- **Decision:** the model is called once, with a forced tool call, rather than through an agentic loop.
- **Why:** it is reading a description and answering with a shape. There is nothing to iterate on and nothing for it to do between turns.
- **Impact:** one request, a JSON Schema the answer has to fit, and a check on the way out that drops any capability not in the catalogue. The assistant cannot name a capability the core cannot build even if it tries.

- **Decision:** no key means the page says so and everything else still works.
- **Why:** an installation that never configures an assistant is a normal installation, not a broken one. Nothing about building an app depends on being able to describe one.
- **Impact:** `ANTHROPIC_API_KEY` is read by the Mobile service alone. Absent, the endpoint answers "the assistant is not configured" and the page shows it as a message rather than an error.

## Outcome

Shipped 2026-08-19. The product shell has a Phone app page for whoever holds
`core.mobile.manage`: describe the app, read the proposal with a reason against
each capability, tick what is right, and build.

Verified without a key: the page renders, the catalogue lists, the existing app
and its builds show, and asking the assistant answers "the assistant is not
configured" rather than failing. The model call itself is unverified, because
this box has no `ANTHROPIC_API_KEY` and putting one there is not something an
agent should do.
