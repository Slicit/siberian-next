---
status: shipped
branch: feat-presigned-uploads
---

# Writing without the bytes coming through

## Intent

The read path stopped carrying bytes two features ago: Storage answers with a
signed URL and the object store sends the file. Writes still went the long way,
so a finished Android build crossed the network three times, once into the
Mobile service, once into Storage, and once into the object store.

The reason it was left is quota. Storage counts bytes as they pass, and a write
it never sees is a write it cannot count, so the obvious version of this feature
loses the accounting that stops one domain filling the disk.

## Decisions

### 2026-08-29: the declared size is no more trusted than what already ships

The quota is checked against a `content_length` the caller states, before any
address is minted. That looks like trusting the client, and it is exactly what
the ordinary write already does: `create` reads `request.content_length`, which
the client also chose, and refuses on that. So this is not a new piece of trust,
it is the same one moved earlier.

What settles it is `confirm`, which asks the object store how big the object
actually is.

### 2026-08-29: confirm recounts rather than adds

Adding the size would be wrong twice. A caller whose confirm timed out will send
it again, and an upload that overwrote an existing object would be counted on
top of the object it replaced.

So confirm recounts the bucket from the object store, which is exact and
idempotent and is the same correction the Backoffice recount performs. It costs
a walk of the bucket, which is the price of having no per-object accounting, and
it is paid once per upload rather than once per request.

That recount only became trustworthy earlier today: `recalculate!` used to sum
the `bytes_used` columns and never look at the store, so it could not correct
the drift a direct write creates. Building this on top of it would have produced
a number that was wrong in a new way.

### 2026-08-29: an unconfirmed upload is an honest gap, not a hidden one

Between the write and the confirm the object exists and the counters do not know
it. The smoke asserts that state rather than papering over it, because it is
real: a caller that dies mid-upload leaves exactly that, and the correction is a
recount rather than a lost file.

### 2026-08-29: the write is tested from outside the stack

The first version of the smoke did the PUT from inside the Storage container and
got `000`. That was the check being right. The minted URL names the object
store's public address, which is the Router's `s3.<domain>` door, and nothing on
the core network resolves it. A caller that could reach it from in there would
not be testing the thing the feature is for.

### 2026-08-29: the builder is not wired to it yet, deliberately

The 67 MB artifact is the reason this exists, and moving it means changing the
protocol between the build worker and the Mobile service: Mobile mints, the
builder writes, Mobile confirms. That is a sound design and it needs a real
Android build to verify, which is the most disk-hungry thing this box does, on a
box with 5.4 GB free and a larger disk on order.

Shipping the capability and leaving the caller for when there is room is the
honest split. Recorded as a candidate rather than left implied.

## Outcome

Shipped as a capability, with the reference client and a smoke.

`bin/smoke-direct-upload` mints an address, writes to the object store from
outside the stack, and checks the accounting through every state:

| | |
|---|---|
| an oversized upload | refused **507**, before any address exists |
| written direct to the store | **200**, no Storage in the path |
| before confirming | counted as **0**, which is the true state |
| after confirming | **24** |
| confirming again | still **24** |
| read back through Storage | the same bytes |

The SDK carries `upload_url` and `confirm`, and the README says plainly that
skipping the confirm loses accounting rather than the file.
