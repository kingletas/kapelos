# syntax=docker/dockerfile:1

# PHP-FPM with every extension Magento 2.4 needs, running as the host user so the files it writes stay yours.
# Its settings live in etc/php and are mounted at run time, so changing one needs a restart, not a rebuild.
ARG PHP_VERSION=8.4
ARG COMPOSER_VERSION=2.10

FROM composer:${COMPOSER_VERSION} AS composer

FROM php:${PHP_VERSION}-fpm AS store

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

# The same PHP as a web server a deployment tool reaches over SSH: sshd for the one user, rsync, and Python for
# Ansible. Only a site with DEPLOY_ROOT builds it; see compose.deploy-target.yaml.
FROM store AS deploy-target

USER root

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends openssh-server rsync python3 sudo acl; \
    rm -rf /var/lib/apt/lists/*

# A deployment becomes the user it logged in as and never root, so that is all sudo allows.
RUN set -eux; \
    echo 'app ALL=(app) NOPASSWD: ALL' > /etc/sudoers.d/app; \
    chmod 440 /etc/sudoers.d/app

# A deployment restarts PHP after it moves the release symlink, so workers stop serving the release they resolved
# before. FPM is process 1 here and reloads on USR2, which is what every verb does: Ansible's restart is stop and then
# start, and a script that only knew restart would report success with the old release still served. nginx follows
# the symlink on each request and Varnish runs in its own container, so those two say they did nothing.
COPY deploy-target/init.d/ /etc/init.d/
RUN set -eux; \
    chmod 755 /etc/init.d/php-fpm /etc/init.d/nginx /etc/init.d/varnish; \
    for v in 8.1 8.2 8.3 8.4 8.5; do ln -sf php-fpm "/etc/init.d/php${v}-fpm"; done

# /app is the live release, so every kapelos command runs on whatever the last deployment made live.
RUN rm -rf /app && ln -s /srv/deploy-root/magento_current /app

COPY deploy-target/sshd_config /etc/ssh/kapelos_sshd_config
COPY deploy-target/ssh_config /etc/ssh/ssh_config.d/kapelos-deploy.conf
COPY deploy-target/entrypoint /usr/local/bin/kapelos-deploy-entrypoint

USER app
WORKDIR /app
