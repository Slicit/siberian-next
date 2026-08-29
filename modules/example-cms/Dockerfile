# A module image. Nothing here knows about Ruby, Rails, or the core's
# internals: the whole contract is HTTP and a Postgres DSN handed over at
# install.
FROM python:3.12-slim

# The core probes the health path the manifest declares from inside this
# container, so the image has to carry an HTTP client. python:3.12-slim ships
# neither wget nor curl, and a module that omits this reports unhealthy while
# serving fine.
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl \
 && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir flask==3.0.3 "psycopg[binary]==3.2.1" "psycopg_pool==3.2.2" gunicorn==22.0.0

WORKDIR /app

# The first-party SDK, copied in rather than installed from an index. The build
# context is the repository root, the same as it is for the core images.
COPY sdk/python/siberian /app/siberian
COPY modules/example-cms/app.py /app/app.py

EXPOSE 8080

# Threaded rather than forked: every request makes a couple of short HTTP calls
# to the core, so the workers are waiting far more than they are computing.
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "--threads", "4", \
     "--access-logfile", "-", "app:app"]
