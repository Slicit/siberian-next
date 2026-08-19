# lib

Shared Ruby for the core apps. Not extracted into gems on purpose: the
isolation that matters is core against modules, and internal core boundaries
do not need packaging ceremony (see `LOGBOOK.md`, Conventions).

| Directory | What it holds |
|---|---|
| `siberian_engine/` | Container engine driver interface and its backends. The only code in this repository allowed to know Docker exists. |
| `contracts/` | Module manifest schema: containers, routes, permissions, capabilities. |
| `client/` | Internal API client used for core to core and core to module calls. |
