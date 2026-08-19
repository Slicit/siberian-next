# SDK

First-party client SDKs so module authors talk to the internal APIs, and to
other modules, without hand-rolling HTTP.

Each SDK covers the same surface: service discovery by short DNS name, the
authenticated call convention, database credential resolution for the current
domain, capability declaration and lookup.

| Directory | Target |
|---|---|
| `ruby/` | Rails and plain Ruby modules |
| `php/` | php-fpm modules |
| `python/` | Python modules |
| `node/` | Node and React modules |

A module never needs an SDK to be valid. The SDKs are convenience over the
internal HTTP API, never a requirement (see `LOGBOOK.md`, Non-goals).
