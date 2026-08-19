# Core

One directory per core container. Each owns its Dockerfile and builds with the
repository root as build context, so `lib/` can be copied in.

| Directory | Container | What it does |
|---|---|---|
| `orchestrator/` | Backoffice | Module install, update, removal, container CRUD, maintenance |
| `base/` | Admin | Wraps every installed module and presents them as one product |
| `auth/` | Auth | OAuth, JWT, 2FA, exposed over the internal API |
| `mailer/` | Mailer | Mail delivery over the internal API |
| `database/` | Database | Provisions databases, brokers scoped credentials |
| `router/` | Router | Routes, per-module origins, internal DNS |
| `configuration/` | Configuration | Core data and configuration store |

See `LOGBOOK.md` for the architecture these mirror.
