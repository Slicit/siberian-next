# Storage

Core capability. Every module gets file storage without ever learning that S3
exists.

## The contract modules see

Plain HTTP against the Storage service by its internal DNS name. No S3 SDK, no
signature algorithm, no credentials to rotate. A module written in PHP, Python,
Rails, or Node uses the same four verbs with whatever HTTP client it already
has, which is what keeps the module contract language-independent.

```
PUT    /v1/{space}/{path}     store, body is the bytes
GET    /v1/{space}/{path}     retrieve
HEAD   /v1/{space}/{path}     size, content type, checksum, mtime
DELETE /v1/{space}/{path}     remove
GET    /v1/{space}            list, ?prefix= &cursor= &limit=
```

Identity is not a parameter. The calling module is established by its internal
API credential and the domain by `X-Siberian-Domain`, both supplied by the
Router. A module cannot name another module's file, because there is no field in
which to name one.

## Spaces

| Space | Lifetime | Reachable from outside | Use |
|---|---|---|---|
| `files` | until deleted | no | dynamic application data |
| `tmp` | swept after `tmp_ttl_hours`, default 168 | no | scratch, uploads in progress, exports |
| `public` | until deleted | yes | assets, avatars, published uploads |

`public` objects are served by the Router at
`https://<module>.apps.<domain>/-/public/<path>`, proxied to the Storage service
rather than to the module container, so serving an asset costs the module
nothing and survives the module being stopped. The `/-/` prefix is reserved by
the core and cannot collide with a module's own routes.

## Behind the API

Garage holds the bytes. One bucket per `(module, domain)` pair, which is the
same isolation rule the Database service follows: containers are shared across
domains, data is not.

```
bucket  sib-<module_name>-<domain_hash>      module_name truncated to 20 chars,
                                             domain_hash is the first 8 hex of
                                             sha256(domain), keeping the name
                                             inside the 63 character S3 limit
key     <space>/<path>
```

**The Storage service holds the only credential.** Garage is not reachable from
the module network at all; it sits on a network only Storage joins. This is why
per-bucket S3 access keys are unnecessary: authorization happens in our API,
against our permission grants, before a request ever becomes an S3 call. It also
means swapping Garage for something else later touches one service.

`tmp` expiry is enforced by a sweeper in the Storage service rather than by
bucket lifecycle rules, because lifecycle configuration is one of the S3 APIs
Garage does not implement.

## Grants

Declared in the module manifest and approved at install time, like every other
permission:

```yaml
permissions:
  storage:
    spaces: [files, public]
    quota_mb: 512
```

A module with no `storage` block gets no storage at all, not an empty bucket.
