# A module image, in PHP, next to a module image in Python. Neither knows
# anything about the core beyond four HTTP endpoints and a Postgres DSN.
FROM php:8.3-cli

# unzip is not optional: composer downloads packages as zips and the php:cli
# image ships with neither the zip extension nor an unzip binary, so it fails
# with a message about ini files that has nothing to do with the cause.
RUN apt-get update && apt-get install -y --no-install-recommends libpq-dev unzip \
    && docker-php-ext-install pdo pdo_pgsql \
    && rm -rf /var/lib/apt/lists/*

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

WORKDIR /app
COPY modules/example-notes/composer.json /app/composer.json
RUN composer install --no-dev --no-interaction --quiet

COPY modules/example-notes/public /app/public

EXPOSE 8080

# The built-in server, with workers. This is a demonstration module: a real one
# would put php-fpm behind nginx, which the manifest can express whenever it
# needs to.
ENV PHP_CLI_SERVER_WORKERS=4
CMD ["php", "-S", "0.0.0.0:8080", "-t", "/app/public"]
