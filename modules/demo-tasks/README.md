# demo-tasks

A to-do list, which is the least interesting thing about it.

It exists to prove the module contract end to end, and to prove it in a language
the core is not written in:

| It uses | How |
|---|---|
| Auth | Reads the session cookie the browser already carries and hands it to `core/auth`, which is the only service that can read it. The module never sees a password and implements no login. |
| Database | Fetches a DSN from `core/database` once, then connects to Postgres directly. Nothing proxies its own queries. |
| System tables | Reads `core.configuration.settings` through the core, because that grant is table-by-table and every read is audited. |
| Storage | Writes one attachment per task with `PUT /storage/v1/files/...`. No S3 client, no signing. |

No SDK is imported anywhere. The dependencies are Flask, psycopg, and gunicorn:
a web framework, a database driver, and a server. Nothing that knows about
Siberian.

## Building

```
bin/build-module demo-tasks
```

The Orchestrator installs by image name. A locally built image is found without
a pull, which is what makes a module developable without a registry.
