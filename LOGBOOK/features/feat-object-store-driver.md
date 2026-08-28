---
status: shipped
branch: feat-object-store-driver
---

# The Storage service speaks Storage, and there is a second backend

## Intent

LOGBOOK already said the object store was a facade and that the backend was a
deployment choice. The code did not agree. `GarageAdmin` was a class in the
Storage service, `GARAGE_ENDPOINT` and `GARAGE_REGION` were read in the object
client, and the Router's S3 door proxied to a host called `garage`. Every one of
those would have to be found and changed on the day somebody moved to a managed
bucket, which is the day nobody wants to be reading code.

So: the same treatment the container engine already has. An interface, a driver
per backend, and a check that fails the build when something outside the driver
names one.

Then a second backend, because an abstraction with one implementation is a guess
about what varies.

Out of scope:

- Migrating objects between backends. Switching a running deployment means
  moving the data, which is an operator's problem with an operator's tools.
- Per bucket IAM identities on AWS. See the decision below.

## Decisions

### 2026-08-29: only the control plane is behind the interface

The obvious move is to put everything behind the driver, including reading and
writing objects. That would be wrong here.

Reading and writing is the S3 protocol. Garage speaks it, AWS speaks it, MinIO
and OVH and Backblaze speak it, and `StoredObjects` already did all of it
through one SDK. Putting that behind the interface means writing it once per
backend in order to abstract the half that was never backend-specific.

What actually differs is everything around the objects: how a bucket comes into
existence, how a credential is minted, and how tightly that credential can be
scoped. That is the whole content of `Driver`, and it is four methods.

`StoredObjects` stayed shared and asks the driver only where to send the request:
`endpoint`, `region`, `force_path_style?`. It was renamed from `ObjectStore`,
which now belongs to the abstraction.

### 2026-08-29: the S3 driver says its credential is not scoped, rather than implying it is

Garage mints a key per bucket in one call. A leaked key reaches one bucket, and
the provisioner was written around that property.

S3 has no equivalent. The nearest is an IAM user per bucket with an inline
policy, which would mean this service holding IAM write permission for the whole
account, one identity per (module, domain) pair against a hard account limit,
and an access key to rotate for each. That is a large amount of blast radius
acquired in order to reduce blast radius.

So the S3 driver hands out the account credential and reports `scoped: false`.
The provisioner logs, once per bucket, that isolation now rests on the Storage
service rather than on the store.

That is not a downgrade so much as an accurate statement of what was always
mostly true: the Storage service is the only holder of any credential, modules
never see one, and every request resolves to a bucket from the module token and
the domain header before a key is touched. What changes is the honesty of the
claim. An operator who wants the stronger promise runs the self hosted backend,
and `scoped?` is how anything above the driver can tell which it got.

### 2026-08-29: a check, because the last abstraction only held because of one

`bin/check-engine-leak` has caught real leaks, and the object store now has the
same guard. It earned itself immediately: the first run failed on
`00-core.conf.template`, where the Router's S3 door proxied to `http://garage:3900`.

That is a genuine coupling and exactly what the check is for. The door now takes
its address from the environment, which also happens to be what the AWS case
needs: against a store the internet can already reach, the door is unnecessary
rather than wrong.

Garage's own `garage.toml` is exempt, for the reason Dockerfiles are exempt from
the engine check. It is the thing being configured, not code choosing it.

### 2026-08-29: drivers load lazily

`lib/object_store.rb` requires a driver only when one is asked for. Otherwise
naming the abstraction would drag `aws-sdk-s3` into six services, and the shared
lib suite runs in a bare Ruby container with no gems at all.

The cost is that a test naming a driver has to require it, which the S3 test
does and says why.

## Outcome

Shipped, both steps.

**The Storage service speaks Storage.** No Ruby outside `lib/object_store` names
a backend, enforced by `bin/check-storage-leak` on every commit. The Router's
door is configured rather than hardcoded. The older `GARAGE_*` variables are
still read as a fallback, so a box configured before this keeps working, which
is how this one was verified without reconfiguring it.

**There is a second backend.** `bin/smoke-s3-backend` stands up a real S3 server
that is not the one this box runs on, and drives the product's own code against
it: provision, provision again, write, read, stream, sign a URL, follow it,
delete, remove the bucket. All thirteen steps pass. It skips rather than fails
when the image cannot be pulled, because a sweep that goes red over a registry
hiccup is one people learn to ignore.

Twelve unit tests cover the parts that are decisions rather than SDK calls: the
`us-east-1` location constraint that must be omitted, a bucket this account
already owns against one another account has taken, a bucket with objects in it
being refused rather than emptied, and the account credential surviving a
deprovision that was handed it.

Against AWS proper this needs an access key with `s3:CreateBucket` and the
bucket operations, or no credentials at all and an instance role, which the
driver leaves to the SDK's own chain rather than defeating with empty strings.
