---
status: shipped
branch: feat-domain-gaps
---

# Adding a domain, and having it work

## Intent

Multi-domain routing shipped, and left two gaps that between them meant adding a
domain still did not work:

- The certificate covered one domain, so a browser refused the others.
- Rails read its allowed hosts at boot, so a new domain answered 403 until every
  core service restarted.

Either one alone makes a new domain unusable, so closing one would have been
closing nothing.

## Decisions

### 2026-08-29: the generator was already right, the workflow was not

The candidate opened with the last feature said `bin/generate-certs` takes one
domain. It does not: it has taken `SIBERIAN_DOMAINS` and built a SAN list from
it since it was written. The certificate on the box was simply generated before
the second domain existed, and nothing said so.

Worth recording as a correction rather than quietly fixing, because the wrong
version was written down and would have sent the next person to rewrite a script
that was already correct.

What was actually missing is that nothing notices. So `RouteReconciler` now
reads the certificate on disk, compares its SAN list against the domains it just
wrote, and reports the difference with the command that fixes it:

```
not in the certificate, so a browser will refuse them: siberian.localhost.
Reissue with SIBERIAN_DOMAINS=siberian.localhost,siberian.test FORCE=true bin/generate-certs
```

Read from the certificate rather than from what it was generated with, because
the file on disk is what a browser is shown.

Reported and not repaired: reissuing needs the CA key and belongs to whoever
runs the box, not to a reconcile that a page load can trigger.

### 2026-08-29: FORCE reissues the leaf and keeps the CA

Following that advice would have made things worse. `FORCE=true` regenerated the
CA as well, so reissuing to add a domain invalidated the CA every machine had
been told to trust, and the symptom is every domain breaking rather than one
being fixed.

The CA now outlives the leaf. Reissuing is routine; replacing the CA costs
everybody a re-trust, so it takes the deliberate act of deleting `ca.pem`.
Verified by fingerprint across a reissue: same CA, longer SAN list.

### 2026-08-29: the host list is published as a file, not asked for

The allowed-host list lives in the Orchestrator's database, which no other
service can read, and it is consulted on the way into every request. A service
that had to call the Orchestrator to find out whether it may answer could not
answer the Orchestrator.

So the Orchestrator publishes the list to the volume it already uses to publish
the Router's configuration, and every service reads it through
`Siberian::ServedDomains`, cached for ten seconds. `config.hosts` takes a
callable rather than strings, because the answer changes while the process runs.

The environment is still merged in, so a deployment that has never reconciled
behaves exactly as it did before this existed.

The matching rule is the part worth testing rather than reasoning about. A
served domain covers its subdomains, because every origin here is one:
`core.<domain>`, `s3.<domain>`, `<module>.apps.<domain>`. That must not become a
suffix match, or registering `notfirst.test` would be served as `first.test`.
There is a test for exactly that.

## Outcome

Shipped, and demonstrated on the running stack rather than argued for.

A domain added with nothing restarted:

| | before adding | after reconcile | after removing |
|---|---|---|---|
| `third.test` | 403 | **302** | 403 |
| `core.third.test` | 403 | **302** | 403 |

Both directions matter. A domain that keeps being served after it is withdrawn
is the same bug as one that is not served after it is added, and the second is
the one anybody notices.

Both existing domains now validate against the real CA rather than needing
`-k`, which is the certificate gap closed:

```
siberian.test 302   core.siberian.test 302
siberian.localhost 302   core.siberian.localhost 302
```

118 lib tests, eleven of them new on the matching rules, and the sweep green.

What is still true: the certificate is reissued by hand. The reconciler names the
domains it does not cover and the command that covers them, which turns a
browser warning nobody can explain into a line in a report.
