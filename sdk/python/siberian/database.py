"""The module's own database: a pooled connection, and a schema applied once.

Two mistakes were in every reference module, both of them in the same six line
helper.

The first is a connection per request. `psycopg.connect` is a TCP connection, a
TLS handshake where configured, and an authentication round trip, per page
view, thrown away at the end of it. Under any load the module spends more time
opening connections than answering.

The second is worse and less visible: the schema call lived inside that helper,
so every request ran `CREATE TABLE IF NOT EXISTS` and `ALTER TABLE ... ADD
COLUMN IF NOT EXISTS`. Those are DDL. Postgres takes an ACCESS EXCLUSIVE lock
to decide it has nothing to do, on every request, on every table the module
owns. It is invisible with one visitor and it serialises the whole module with
twenty.

So the schema is applied once per domain, on first use, and the connections
come from a pool.
"""

import threading

import psycopg
from psycopg_pool import ConnectionPool


class Database:
    """Connections to this module's own database, one pool per domain.

    Per domain because that is where isolation lives: the container is shared
    across every domain the system serves, and the credentials are not. A pool
    keyed on anything coarser would hand a request the wrong domain's data,
    which is the one bug in this file that would not look like a bug.
    """

    def __init__(self, core, token, domain_source, schema=None,
                 min_size=1, max_size=8):
        self._core = core
        self._token = token
        self._domain_source = domain_source
        self._schema = schema
        self._min_size = min_size
        self._max_size = max_size

        self._pools = {}
        self._migrated = set()
        self._lock = threading.Lock()

    def dsn(self, domain=None):
        """The connection string the core issued for this (module, domain).

        Nothing proxies the connection itself. The Database service mints a
        credential scoped to the pair and gets out of the way, which is what
        keeps it off the path of a module reading its own rows.
        """
        domain = domain or self._domain_source()
        return self._core.call("/database/v1/credentials", self._token)["url"]

    def connection(self):
        """A pooled connection, as a context manager.

            with siberian.db.connection() as connection:
                with connection.cursor() as cursor:
                    ...

        Returning it to the pool is the caller's business only in the sense
        that leaving the `with` block does it for them.
        """
        return self._pool_for(self._domain_source()).connection()

    def migrate(self, schema=None):
        """Apply the schema for the current domain, once.

        Safe to call as often as anyone likes: it does the work the first time
        for a domain and is a set membership test afterwards. That is the whole
        point, because the natural place to call it is somewhere that runs
        often.
        """
        statements = schema if schema is not None else self._schema
        if not statements:
            return

        domain = self._domain_source()
        if domain in self._migrated:
            return

        with self._lock:
            # Checked again inside the lock: two requests for a new domain
            # arriving together would otherwise both run the DDL, and while
            # `IF NOT EXISTS` makes that harmless it also makes it pointless.
            if domain in self._migrated:
                return

            with self._pool_for(domain).connection() as connection:
                with connection.cursor() as cursor:
                    for statement in statements:
                        cursor.execute(statement)

            self._migrated.add(domain)

    def close(self):
        with self._lock:
            for pool in self._pools.values():
                pool.close()
            self._pools.clear()
            self._migrated.clear()

    def _pool_for(self, domain):
        pool = self._pools.get(domain)
        if pool is not None:
            return pool

        with self._lock:
            pool = self._pools.get(domain)
            if pool is not None:
                return pool

            # `open=True` connects now rather than on first use, so a bad
            # credential is an error at startup rather than a surprise in the
            # middle of somebody's page.
            pool = ConnectionPool(
                conninfo=self.dsn(domain),
                min_size=self._min_size,
                max_size=self._max_size,
                # Autocommit matches how the reference modules were written and
                # what most module code wants: a request that does one UPDATE
                # should not have to remember to commit it.
                kwargs={"autocommit": True},
                open=True,
                name=f"siberian-{domain}",
            )
            self._pools[domain] = pool
            return pool


__all__ = ["Database", "psycopg"]
