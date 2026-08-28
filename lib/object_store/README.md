# Object store driver

The object store sits behind an interface, the same way the container engine
does and for the same reason: which store a deployment uses is a deployment
decision, and nothing above the driver should be able to tell which one it got.

```
Siberian::ObjectStore.driver   # => a Driver, chosen by SIBERIAN_OBJECT_STORE
```

| Backend | Key | Notes |
|---|---|---|
| Garage | `garage` | Self hosted, the default. Mints a key per bucket. |
| AWS S3 | `s3` | Managed. Also reaches anything S3 compatible with an access key. |

## What is behind the interface, and what is not

Only the control plane. Creating a bucket, minting a credential, and scoping
that credential are three things every store does differently, and they are the
whole content of `Driver`.

Reading and writing objects is not here. That half is the S3 protocol, every
store worth supporting speaks it, and `StoredObjects` in the Storage service
does it once for all backends, parameterised by `endpoint`, `region`, and
`force_path_style?`. Writing it twice would be duplicating the part that is
already portable in order to abstract the part that already is.

## The interface

```ruby
driver.name                 # "garage" | "s3", for logs, never to branch on
driver.healthy?             # false rather than raising: the health card asks

driver.provision(name)      # => Provisioned(access_key_id:, secret_access_key:,
                            #                handle:, scoped:)
driver.deprovision(name:, handle:, access_key_id:)
driver.exists?(name)

driver.endpoint             # where S3 is spoken from inside the stack
driver.public_endpoint      # where a browser reaches it, or nil
driver.region
driver.force_path_style?
```

`scoped` is the one field worth explaining. Garage mints a key that reaches
exactly one bucket, so a leaked credential reaches one domain's files. AWS has
no equivalent that does not involve creating an IAM identity per bucket, so its
driver reports `scoped: false` and the Storage service records that the
isolation now rests on it rather than on the store. A backend that cannot make a
promise says so instead of implying it.

## Adding a backend

1. `lib/object_store/drivers/<name>.rb`, subclassing `Driver`.
2. Add it to `BACKENDS` in `lib/object_store.rb`.
3. Nothing else. If something else has to change, the interface is wrong and
   should grow rather than being worked around.

`bin/check-storage-leak` fails the build if a backend is named in code outside
this directory, which is what keeps step 3 true.

## Configuration

Read from the environment, backend-neutral names first:

```
SIBERIAN_OBJECT_STORE                  garage | s3
SIBERIAN_OBJECT_STORE_ENDPOINT         where S3 is spoken, inside
SIBERIAN_OBJECT_STORE_PUBLIC_ENDPOINT  where a browser reaches it
SIBERIAN_OBJECT_STORE_REGION
SIBERIAN_OBJECT_STORE_ACCESS_KEY_ID    s3 only
SIBERIAN_OBJECT_STORE_SECRET_ACCESS_KEY
SIBERIAN_OBJECT_STORE_ADMIN_ENDPOINT   garage only
SIBERIAN_OBJECT_STORE_ADMIN_TOKEN      garage only
```

The Garage driver still reads its older `GARAGE_*` names as a fallback, so a
box configured before this existed keeps working.
