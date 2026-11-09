ARG PHPV=8.3
FROM php:${PHPV}-cli
# Old Debian bases (php 7.4) have archived apt repos; these extras are optional for path-repo installs.
RUN sed -i 's/deb.debian.org/archive.debian.org/;s#security.debian.org#archive.debian.org#' /etc/apt/sources.list 2>/dev/null || true
RUN (apt-get -o Acquire::Check-Valid-Until=false update -qq \
     && apt-get install -y -qq git unzip libzip-dev libicu-dev >/dev/null \
     && docker-php-ext-install zip intl >/dev/null) || echo "[dockerfile] apt extras skipped"
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer
ENV COMPOSER_ALLOW_SUPERUSER=1 COMPOSER_NO_INTERACTION=1
