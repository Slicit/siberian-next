---
status: shipped
branch: feat-signed-urls
---

# Taking services out of the byte path

## Intent

The review on 2026-08-22 counted the copies. A CMS image on a phone was
fetched by the Router, proxied whole through the module's own Python process,
fetched again through the Router's core door, read whole into the Storage
service, and only then streamed out of Garage. Four buffered copies of every
image, two of them holding the entire file in a language runtime that had no
reason to see it.

At demo scale that is invisible. It is also the latency floor and the memory
ceiling, and it is the reason a module serving a photograph costs more than a
module serving a page of text.

Two separate problems wear the same clothes here, and only one of them is about
hops:

- **Buffering.** `object.body.read` puts a whole object in Ruby's heap for as
  long as the download takes, once per concurrent reader.
- **Detours.** A module proxying its own public media is a hop that exists only
  because the URL pointed at the module.

Out of scope for this feature:

- Presigned URLs straight to Garage. See the decision below: the topology this
  project deliberately chose makes that a bigger question than it looks, and it
  is the user's to answer rather than mine.
- Presigned uploads. Same reason, plus quota accounting happens while the bytes
  are in flight.

## Plan

1. Storage streams objects instead of reading them whole.
2. The Mobile service streams an artifact through to Storage rather than
   holding it.
3. A public path on the Router, served straight from Storage, so a module hands
   out a URL instead of copying bytes.
4. The CMS module uses it, and its media proxy goes.
5. `bin/smoke-public-media` proves both what works and what must not.

## Decisions

### 2026-08-22: presigned URLs need a topology decision, so they are not in this

The proposal said Storage would mint short-lived signed URLs and hand them out.
Garage speaks S3 and presigning is free, so this looked like the cheap half.

It is not, and the reason is in `deploy/compose.yml`: Garage is on the
`storage` network, the Router is on `core`, and the Storage service is the only
container attached to both. That is deliberate and LOGBOOK says so ("on an
internal-only network the Storage service alone joins"). A presigned URL names
a host the browser has to reach, and no browser can reach `garage:3900`.

Making it reachable means attaching the Router to the storage network. That is
not a config tweak, it is a change to what a compromised Router gets: today it
has no path to the object store at all, and afterwards it has one. The
invariant it would weaken is written down in LOGBOOK, which is not a file to
edit as a side effect of a performance change.

So this feature takes the hops out without moving Garage, and the presigning
question is left as a decision to put to the user with its cost stated.

### 2026-08-22: the public space needs no token, and that is the point

`PublicFilesController` is the only route in Storage that does not establish
who is calling. It cannot: the caller is a browser loading an image.

What makes it safe is the space rather than the caller. An object in `public`
is there because a module asked for the public space in its manifest and an
operator approved it, and "anyone may read this" is what that approval means.
The module is a path segment rather than a proved identity, so the widest thing
this can be pointed at is a public object of some module on the domain the
Router says the request arrived for, which is a set of bytes that were already
world readable.

The narrowing is done in three places rather than trusted to one: the space is
a constant and never a parameter, a module that was not granted `public`
answers 404 rather than 403 so the route cannot be used to enumerate installed
modules, and the domain comes from the header the Router sets rather than from
anything the client can write.

### 2026-08-22: the core door refused every upload over a megabyte

Found while measuring, not by looking: a 1.1 MB `PUT` through
`http://core/storage/...` came back 413, and a 900 KB one came back 201.

nginx defaults `client_max_body_size` to 1m and nothing had ever set it. So the
Storage service's quotas, which an operator sets per bucket and per domain and
can see in the Backoffice, were a fiction above a megabyte: a module granted
512 MB could not store a photograph, and the refusal mentioned neither quotas
nor nginx.

The limit now sits well above the default bucket grant, so the refusal comes
from the quota that an operator can actually see and change. It is not removed
altogether, because a body large enough to be a denial of service should still
stop at the door. Verified after the fix: 1.1 MB stores, and 30 MB is refused
by the bucket quota with the numbers in the response rather than by nginx.

This is the second time in two features that a limit nobody set has been doing
the deciding. Worth remembering that a default is a decision somebody else made.

## Outcome

Shipped, and verified against the running stack rather than a mock.

What changed, measured:

- Storage streams. `show` no longer builds a String of the object; the SDK's
  block form yields chunks into an Enumerator that Rack writes as they arrive.
- The Mobile service streams an artifact through to Storage with
  `body_stream`, so a finished Android build is no longer held in that process
  on top of the copy Storage was holding.
- A CMS image is now one hop: the Router asks Storage, Storage streams from
  Garage. It was four, two of them buffered. The real content type survives,
  which it did not when the module proxied and guessed it from the file
  extension.
- Uploads over 1 MB work at all, which they did not before.

`bin/smoke-public-media` covers the parts that must work (no token, both
origins, real content type, nosniff) and the parts that must not: three
spellings of path traversal aimed at a private object in the same bucket, all
404, and an unknown module name, also 404.

Left for a decision rather than left undone: presigned URLs, which would take
Storage out of the read path entirely, and presigned uploads, which would take
it out of the write path. Both need Garage reachable from a browser, and that
is a topology change with a security cost that belongs to whoever owns the
threat model.

### 2026-08-22: the Router reaches Garage, and still cannot read anything

Asked to route public object store URIs from the Router the way an external S3
service would, which meant finding out what Garage actually offers. Two things,
from its own API rather than from documentation:

- `websiteAccess` is a boolean on the bucket.
- A key's permissions are `{read, write, owner}` on the bucket.

Neither has any notion of a prefix. One bucket holds `public/`, `files/`, and
`tmp/` for a (module, domain) pair, so making that bucket publicly readable
would publish every private file in it. The S3 way to have a public bucket is
to have a second bucket, and splitting every module's storage in two is a large
change with a leak at the end of it if any part is wrong.

Presigned URLs get the same result without that. Storage signs with the
bucket's own key, so a URL grants one object for one hour and nothing else, and
the Router only has to forward it.

What the Router gains is reachability, not authority. It holds no Garage
credential and cannot sign anything, so it can serve only what the caller
already had a valid signature for. Verified rather than assumed, against the
running stack: an unsigned request, a tampered signature, a signature whose key
was edited to a private object in the same bucket, and one pointed at a
different bucket entirely are all refused with 403.

The signature covers the host and the path, which is why the door is
`s3.<domain>` and not a path on the product domain: the path arriving at Garage
has to be exactly the `/<bucket>/<key>` that was signed, and a rewrite would
invalidate it. The wildcard certificate already covers the name.

## Outcome, revised

Public media is now served by the object store itself. Storage answers with a
302 to a signed URL and carries no bytes at all; before this feature it read
every object into a String, and between the first half of this feature and this
one it streamed them.

For a CMS image on a phone the path went from four copies, two of them buffered
in a language runtime, to none: the Router forwards a signed request and Garage
answers it.
