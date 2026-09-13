# syntax=docker/dockerfile:1

# PHP-FPM with every extension Magento 2.4 needs, running as the host user so the files it writes stay yours.
# Its settings live in etc/php and are mounted at run time, so changing one needs a restart, not a rebuild.
ARG PHP_VERSION=8.4
ARG COMPOSER_VERSION=2.10

FROM composer:${COMPOSER_VERSION} AS composer

FROM php:${PHP_VERSION}-fpm

ARG REDIS_VERSION=6.3.0
ARG XDEBUG_VERSION=3.5.3
ARG INSTALL_SOURCEGUARDIAN=false
ARG SOURCEGUARDIAN_URL=https://www.sourceguardian.com/loaders/download/loaders.linux-x86_64.tar.gz

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        git \
        unzip \
        msmtp \
        mariadb-client \
        libfreetype6-dev \
        libjpeg62-turbo-dev \
        libpng-dev \
        libicu-dev \
        libxml2-dev \
        libxslt1-dev \
        libzip-dev; \
    rm -rf /var/lib/apt/lists/*; \
    docker-php-ext-configure gd --with-freetype --with-jpeg; \
    docker-php-ext-install -j"$(nproc)" bcmath ftp gd intl opcache pcntl pdo_mysql soap sockets xsl zip; \
    pecl install "redis-${REDIS_VERSION}" "xdebug-${XDEBUG_VERSION}"; \
    docker-php-ext-enable redis xdebug; \
    # Xdebug lives on its own so a scan directory can leave it out. SourceGuardian refuses
    # to decode while a debugger extension is loaded, and compiling reads every class.
    mkdir -p "${PHP_INI_DIR}/xdebug.d"; \
    mv "${PHP_INI_DIR}/conf.d/docker-php-ext-xdebug.ini" "${PHP_INI_DIR}/xdebug.d/"; \
    rm -rf /tmp/pear

# The vendor publishes no checksum, so I trust this download on HTTPS alone, and leave it off unless asked for.
RUN set -eux; \
    if [ "${INSTALL_SOURCEGUARDIAN}" = "true" ]; then \
        mkdir /tmp/sourceguardian; \
        curl -fsSL "${SOURCEGUARDIAN_URL}" | tar -xz -C /tmp/sourceguardian; \
        php_minor="$(php -r 'echo PHP_MAJOR_VERSION, ".", PHP_MINOR_VERSION;')"; \
        cp "/tmp/sourceguardian/ixed.${php_minor}.lin" "$(php-config --extension-dir)/sourceguardian.so"; \
        echo 'extension=sourceguardian.so' > "${PHP_INI_DIR}/conf.d/00-sourceguardian.ini"; \
        rm -rf /tmp/sourceguardian; \
    fi

COPY --from=composer /usr/bin/composer /usr/local/bin/composer

# Declared here, not at the top, so a different user reuses every cached layer above.
ARG UID=1000
ARG GID=1000

RUN set -eux; \
    groupadd --non-unique --gid "${GID}" app; \
    useradd --non-unique --uid "${UID}" --gid "${GID}" --create-home --shell /bin/bash app; \
    mkdir -p /home/app/.composer; \
    chown app:app /home/app/.composer

ENV COMPOSER_HOME=/home/app/.composer \
    XDEBUG_MODE=off \
    SMTP_HOST=mailpit \
    SMTP_PORT=1025

USER app
WORKDIR /app
