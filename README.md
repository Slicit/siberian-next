# Siberian Next

A container orchestrator for modular applications. The core provisions and wires
containers, modules ship as container groups in any language, and everything
talks over an internal API instead of an in-process plugin ABI.

Architecture, conventions, and non-goals live in [`LOGBOOK.md`](LOGBOOK.md).
Read that first; this file only tells you how to run things.

## Layout

```
core/       one directory per core container
lib/        shared Ruby for the core apps
sdk/        per-language module SDKs
modules/    first-party reference modules
deploy/     compose for development, Kubernetes manifests later
bin/        development entry points
```

## Getting started

```
bin/setup              check prerequisites, write .env
bin/new-rails-app base generate a core Rails service, in a container
bin/up                 bring up the core
bin/check              everything checkable without a running stack
```

Ruby is not a host prerequisite. A container engine is: the Orchestrator drives
one, and the Rails services are generated and run inside containers.

## Status

Skeleton. The shape, the module contract, and the engine interface are defined.
No service is implemented yet. See
[`LOGBOOK/features/feat-monorepo-skeleton.md`](LOGBOOK/features/feat-monorepo-skeleton.md).
