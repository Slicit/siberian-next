# siberian_engine

The container engine behind an interface. Docker is the first backend;
Kubernetes or an equivalent comes later without rewriting the core.

**This directory is the only code in the repository allowed to know Docker
exists.** Nothing above it names a container engine, an image, or a network in
engine-specific terms. If a feature needs an engine capability that the
interface does not expose, the interface grows; the caller does not reach past
it. `bin/check-engine-leak` enforces this.

## Shape

- `Driver` is the abstract interface. Every backend implements all of it.
- `ContainerSpec` is the engine-neutral description of one container. The
  Orchestrator builds specs from module manifests and hands them to the driver.
- `drivers/` holds the backends.

## Naming

Container names are `<uuid>-<module_name>-<service>`, assigned by the caller,
never by the driver. Each container also carries the module's short name as a
network alias, which is what makes module to module calls resolvable by short
DNS name through the Router.
