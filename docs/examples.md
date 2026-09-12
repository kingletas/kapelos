# Examples

Ready-to-use recipes for everything Kapelos does, from trying Magento for the first time to giving a store commands of its own. Each one starts with what you're trying to do, then the commands.

The examples type `kapelos`, put on your `PATH` with `make install` as the [README](../README.md#everyday-commands) shows. `bin/kapelos` from Kapelos's folder does exactly the same. The store in them is called `acme`, and every hostname, address and person in them is made up.

## Contents

- [Everyday recipes](#everyday-recipes)
    - [Try Magento without an account](#try-magento-without-an-account)
    - [Start a project on a folder of your own](#start-a-project-on-a-folder-of-your-own)
    - [Work on a copy of a teammate's database](#work-on-a-copy-of-a-teammates-database)
    - [Run a store exactly as it is](#run-a-store-exactly-as-it-is)
    - [Switch between projects](#switch-between-projects)
    - [Look inside the database and the caches](#look-inside-the-database-and-the-caches)
    - [Save a clean state and go back to it](#save-a-clean-state-and-go-back-to-it)
    - [Hand your database to someone](#hand-your-database-to-someone)
    - [Debug a page or a command](#debug-a-page-or-a-command)
    - [Profile a slow page](#profile-a-slow-page)
    - [Test full-page caching](#test-full-page-caching)
    - [Use HTTPS with a trusted certificate](#use-https-with-a-trusted-certificate)
    - [Run two storefronts from one store](#run-two-storefronts-from-one-store)
    - [Build the theme's styles](#build-the-themes-styles)
    - [Run cron](#run-cron)
    - [Try the store on another PHP version](#try-the-store-on-another-php-version)
    - [Rehearse a deployment](#rehearse-a-deployment)
    - [Run the tests](#run-the-tests)
    - [Run CI before you push](#run-ci-before-you-push)
    - [Audit a store before a release](#audit-a-store-before-a-release)
    - [Place test orders in a browser](#place-test-orders-in-a-browser)
    - [Bundle the JavaScript](#bundle-the-javascript)
    - [Work on a module from another folder](#work-on-a-module-from-another-folder)
    - [Use the mail catcher you already run](#use-the-mail-catcher-you-already-run)
    - [Check your machine](#check-your-machine)
    - [Remove a site](#remove-a-site)
- [Giving a store its own stack](#giving-a-store-its-own-stack)
    - [The folder](#the-folder)
    - [Pin the stack to the store](#pin-the-stack-to-the-store)
    - [Bring the store's nginx rules](#bring-the-stores-nginx-rules)
    - [Change PHP's settings](#change-phps-settings)
    - [Add a fake of an outside service](#add-a-fake-of-an-outside-service)
    - [Keep a queue consumer running](#keep-a-queue-consumer-running)
    - [Trust it](#trust-it)
- [Your own commands](#your-own-commands)
    - [The ones Kapelos ships](#the-ones-kapelos-ships)
    - [How a command works](#how-a-command-works)
    - [A first command: is everything up?](#a-first-command-is-everything-up)
    - [A new teammate's first hour, in one command](#a-new-teammates-first-hour-in-one-command)
    - [Replace real customers with made-up ones](#replace-real-customers-with-made-up-ones)
    - [Run PHP inside the store](#run-php-inside-the-store)
    - [Build a theme with Node](#build-a-theme-with-node)
    - [A command in another language](#a-command-in-another-language)
    - [Commands just for you](#commands-just-for-you)
    - [Writing one without trusting it every time you save](#writing-one-without-trusting-it-every-time-you-save)
- [Scripting Kapelos](#scripting-kapelos)
    - [Exit codes and questions](#exit-codes-and-questions)
    - [Check another site without switching](#check-another-site-without-switching)
    - [Run the tests before every push](#run-the-tests-before-every-push)
    - [Audit a store every week](#audit-a-store-every-week)
    - [Rehearse an upgrade you can undo](#rehearse-an-upgrade-you-can-undo)

## Everyday recipes

### Try Magento without an account

```bash
kapelos demo
```

That downloads Mage-OS, installs it at <http://localhost:8080/> and prints where everything is. To have a catalogue to click through, add Magento's sample products:

```bash
kapelos sample-data
```

### Start a project on a folder of your own

```bash
kapelos env acme              # writes etc/sites/acme.env
```

Open `etc/sites/acme.env`, set `MAGENTO_SRC` to the store's folder, then:

```bash
kapelos use acme
kapelos up
kapelos magento-install
```

The store answers at `http://acme.test:8080/`. Add `127.0.0.1 acme.test` to `/etc/hosts` so that name reaches your machine.

If you'd rather answer a few questions than edit a file, `kapelos interactive` does all of this.

### Work on a copy of a teammate's database

You have the store's code and a dump a teammate sent you:

```bash
kapelos env acme              # then set MAGENTO_SRC in etc/sites/acme.env
kapelos use acme
kapelos up
kapelos import ~/Downloads/acme.sql.gz
kapelos connect
```

`connect` rewrites the store's `app/etc/env.php` for this stack and puts it in developer mode. The admin logins are the ones in the dump, so make one of your own. Magento asks for each detail:

```bash
kapelos admin:user:create
```

### Run a store exactly as it is

A production copy, a store another stack also runs, or one you mustn't change:

```bash
kapelos adopt ~/projects/acme --datadir ~/projects/acme-db
```

`--datadir` copies a MariaDB data directory, which is far faster than a dump for a big database. Stop the server that uses it first. With a dump instead:

```bash
kapelos adopt ~/projects/acme --dump ~/Downloads/acme.sql.gz --url http://acme.test:8080/
```

The store's code and its `app/etc/env.php` stay as they are. Kapelos lays its own settings over them inside the containers. The README's [Adopting a store](../README.md#adopting-a-store) explains what it keeps and what it changes.

### Switch between projects

```bash
kapelos sites                 # the * is the active one
kapelos use shop2             # stops acme, keeping its data
kapelos up
```

Only one site runs at a time. The next `kapelos use acme` and `kapelos up` bring it back exactly as you left it.

### Look inside the database and the caches

```bash
kapelos db                                        # a MariaDB prompt
kapelos db <<<'SELECT sku, type_id FROM catalog_product_entity LIMIT 5'
kapelos db < report.sql                           # a file of SQL
kapelos valkey cache DBSIZE                       # how many cache entries there are
kapelos valkey session KEYS '*'                   # the sessions
kapelos config:show web/secure/base_url           # a Magento setting
```

`kapelos info` prints the database port and password, for a database tool on your machine.

### Save a clean state and go back to it

Before a test that changes the store, such as an import or a checkout run:

```bash
kapelos snapshot save clean
# ... do whatever you like to the store ...
kapelos snapshot restore clean    # asks first
```

A snapshot is the database, the search index and the queue. `kapelos snapshot` lists them, and `kapelos snapshot delete clean` removes one.

### Hand your database to someone

```bash
kapelos db dump                         # var/dumps/ in Kapelos's folder
kapelos db dump ~/acme-for-review.sql.gz
```

The file is readable only by you. If the store holds real customers, [replace them with made-up ones](#replace-real-customers-with-made-up-ones) before it goes anywhere.

### Debug a page or a command

1. In your IDE, listen for Xdebug on port 9003 and map `/app` to the store's folder.
2. Open the page with `?XDEBUG_TRIGGER=1` on the end, or turn on the Xdebug browser extension.

Only requests that ask for Xdebug go to the PHP that has it on, so everything else stays fast. For a command:

```bash
kapelos debug indexer:reindex catalog_product_price
```

### Profile a slow page

In the site's settings, `etc/sites/acme.env`:

```bash
XDEBUG_MODE=debug,profile
```

Then:

```bash
kapelos up
curl -s -o /dev/null 'http://acme.test:8080/women.html?XDEBUG_TRIGGER=1'
ls var/                           # in the store's folder: cachegrind.out.*.gz
```

Open the file in KCachegrind, QCachegrind or your IDE's profiler view.

### Test full-page caching

```bash
kapelos config:set system/full_page_cache/caching_application 2
kapelos varnish:vcl:generate --export-version=7 --backend-host=web --backend-port=80 \
  --access-list=0.0.0.0/0 --output-file=var/varnish.vcl
```

On Mage-OS, read the README's [note on the generator](../README.md#full-page-caching-with-varnish) first. Set `VARNISH_VCL` in the site's settings to that file, which is `var/varnish.vcl` inside the store's folder, then `kapelos up`. Load a page twice:

```bash
curl -sI http://acme.test:8080/ | grep -i x-magento-cache-debug    # MISS, then HIT
```

### Use HTTPS with a trusted certificate

With [mkcert](https://github.com/FiloSottile/mkcert) installed:

```bash
kapelos cert
kapelos config:set web/secure/base_url https://acme.test:8443/
kapelos config:set web/unsecure/base_url https://acme.test:8443/
```

Set `MAGENTO_BASE_URL=https://acme.test:8443/` in the site's settings too, so Kapelos's own checks and the browser tools use the same address.

If the browser still warns, run `mkcert -install` once yourself. It changes which certificates your whole system trusts, so Kapelos doesn't run it for you.

### Run two storefronts from one store

A store with a second store view, `outlet`, that should answer at `outlet.test`:

```bash
# etc/sites/acme.env
STORES="outlet.test=outlet"
```

```bash
kapelos up
kapelos stores            # which store each hostname runs, and whether the database has it
kapelos stores apply      # sets the outlet store's address
```

Add `127.0.0.1 outlet.test` to `/etc/hosts`. Every hostname that isn't listed runs the default store.

### Build the theme's styles

Magento's own grunt setup, with the sample files copied first:

```bash
cp package.json.sample package.json
cp Gruntfile.js.sample Gruntfile.js
kapelos npm install
kapelos grunt exec:luma less:luma
kapelos grunt watch         # rebuilds as you save, with LiveReload on port 35729
```

Node runs in its own container at the store's folder. `NODE_VERSION` in the site's settings picks the version.

### Run cron

```bash
kapelos cron on             # every minute, from now on
kapelos cron                # on or off, and what ran in the last hour
kapelos cron run            # one run, now
kapelos cron off
```

On a store you brought, `cron on` asks first, because its jobs use the store's real settings: feeds, exports and emails to outside servers. To run one queue consumer by hand instead, and watch it work:

```bash
kapelos queue:consumers:list
kapelos queue:consumers:start product_action_attribute.update
```

`queue:consumers:start` keeps waiting for new messages after its queue is empty, so stop it with Ctrl+C.

If the consumer stops at once with `NOT_FOUND - no queue`, RabbitMQ doesn't have the store's queues yet. `kapelos queues` declares them without running `setup:upgrade`, and checks each one is there.

### Try the store on another PHP version

```bash
# etc/sites/acme.env
PHP_VERSION=8.3
```

```bash
kapelos build
kapelos up
kapelos test unit
```

Each PHP version gets its own image, so switching back to 8.4 is instant. If the store's `.kapelos/settings.env` sets `PHP_VERSION`, that wins over the site's settings.

### Rehearse a deployment

```bash
kapelos deploy              # the production steps, in order, on your tree
kapelos develop             # back to working on it
```

If a step fails, `deploy` stops, names it and leaves the store in maintenance mode, as a real deployment would. `develop` gets you out of that too.

### Run the tests

```bash
kapelos test                                     # unit and integration tests under app/code
kapelos test unit app/code/Acme/Checkout         # one module's unit tests
kapelos test integration app/code/Acme/Checkout  # its integration tests, in a database of their own
```

### Run CI before you push

```bash
kapelos ci                  # every workflow in .github/workflows, as a push would
kapelos ci -l               # list the jobs
kapelos ci -j phpstan       # one job
kapelos ci pull_request     # as a pull request would
```

Each job gets a copy of the store, so a workflow can't change your files.

### Audit a store before a release

```bash
kapelos site audit          # the active site
kapelos site audit acme     # any site, running or not
```

`site audit` checks dependencies, credentials in the code, security settings, stray files in `pub/` and the headers Magento sends. It exits 1 if anything failed.

### Place test orders in a browser

On a store whose settings say `DISPOSABLE=yes`, which `demo` sets:

```bash
kapelos sample-data
kapelos bluetir probe             # does every selector resolve? places nothing
kapelos bluetir                   # adds to the cart, checks out, places an order
kapelos bluetir order --runs 10
kapelos drexbot
```

On any other store, bluetir refuses to place orders and says which of its modes still work.

### Bundle the JavaScript

```bash
kapelos deploy
kapelos manipulus                 # plan the bundles
kapelos manipulus build           # write them, and the module that loads them
kapelos deploy                    # put them live
```

### Work on a module from another folder

A module you're writing in its own repository, mounted into the store only on your machine. Make `compose.local.yaml` in Kapelos's folder:

```yaml
services:
  php:
    volumes: &module
      - ~/projects/module-acme-loyalty:/app/app/code/Acme/Loyalty
  php-debug:
    volumes: *module
  cron:
    volumes: *module
```

Mount it into all three PHP containers, or a request with Xdebug or a scheduled job finds the module switched on and its code missing. Check the path: if it doesn't exist, Docker makes an empty folder there and mounts that.

Add it to the site's `COMPOSE_FILE`, then bring the stack up and enable the module:

```bash
# etc/sites/acme.env
COMPOSE_FILE=compose.yaml:compose.local.yaml
```

```bash
kapelos up
kapelos module:enable Acme_Loyalty
kapelos setup:upgrade
```

`compose.local.yaml` is ignored by git. For additions everyone on the store needs, use the store's own [`.kapelos/compose.yaml`](#giving-a-store-its-own-stack).

### Use the mail catcher you already run

In the site's settings, take `mail` out of `COMPOSE_PROFILES` and point PHP at yours:

```bash
COMPOSE_PROFILES=
SMTP_HOST=host.docker.internal
SMTP_PORT=1025
```

Then `kapelos down` and `kapelos up`. `up` alone leaves Mailpit running.

### Check your machine

```bash
kapelos doctor
```

`doctor` checks Docker, memory, disk and tools, then the active site: its settings, ports, hostname, certificate, trust and service versions. Run it first when something won't start.

### Remove a site

```bash
kapelos site remove acme
```

`site remove` lists everything it will delete, then asks you to type the site's name. The store's code stays where it is, unless Kapelos downloaded it.

## Giving a store its own stack

Everything above lives on your machine. A store can also carry its Kapelos setup in its own repository, so everyone who clones it gets the same stack.

### The folder

```text
.kapelos/
├── settings.env          facts about the store: versions, nginx rules, storefronts
├── nginx.conf            the store's own nginx rules, if it has any
├── php.ini               PHP settings the store needs
├── compose.yaml          services the store needs, merged over Kapelos's own
├── mocks/                files a service in compose.yaml reads
└── commands/             commands of the store's own
    ├── smoke
    ├── setup
    └── lib/              helpers the commands use; not commands themselves
```

Only `settings.env`, `compose.yaml` and `commands/` mean anything to Kapelos. The other files are there because those three point at them.

### Pin the stack to the store

`settings.env` holds facts about the store, and wins over the site's settings for them:

```bash
# .kapelos/settings.env
PHP_VERSION=8.3
NODE_VERSION=20
OPENSEARCH_VERSION=3.6.0
STORES="outlet.test=outlet"
DEPLOY_LOCALES="en_US fr_FR"
MANIPULUS_THEME=frontend/Acme/default
MAGENTO_NGINX_CONF=/app/.kapelos/nginx.conf
AUDIT_PATHS="app/code app/design"
```

`etc/magento-versions.tsv` lists the service versions each Magento release supports, and `kapelos doctor` warns when the site runs one outside them.

**If you pin `MARIADB_VERSION`, do it before anyone's database is made.** A newer MariaDB upgrades the database's files when it starts on them, and an older one can't read them afterwards. So a store that pins 11.4 stops a teammate whose database 11.8 already wrote.

This file comes with the store's code, so it can't open ports, change passwords or name a folder on your machine. Kapelos refuses the whole file, naming the line, if it tries.

### Bring the store's nginx rules

Magento's own nginx rules run only its four entry points, so any other PHP script in `pub/` answers 404. If the store's real server runs one, say a `pub/feed.php`, write the rule once and include Magento's rules after it:

```nginx
# .kapelos/nginx.conf
location = /feed.php {
    fastcgi_pass fastcgi_backend;
    include fastcgi_params;
    fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
}

include /app/nginx.conf.sample;
```

Point `MAGENTO_NGINX_CONF` at it in `settings.env`, as above, and run `kapelos up`. After that, an edit to the file needs only `kapelos restart web web-debug`.

### Change PHP's settings

Kapelos's own PHP settings are `etc/php/kapelos.ini`. A store that needs different ones mounts its own file after it, so its values win:

```ini
; .kapelos/php.ini
max_input_vars = 20000
upload_max_filesize = 128M
post_max_size = 128M
```

```yaml
# .kapelos/compose.yaml
services:
  php:
    volumes: &store-ini
      - ${MAGENTO_SRC}/.kapelos/php.ini:/usr/local/etc/php/conf.d/zz-store.ini:ro
  php-debug:
    volumes: *store-ini
  cron:
    volumes: *store-ini
```

- **All three PHP containers get it**: `php` serves pages, `php-debug` serves the requests that ask for Xdebug, and `cron` runs the scheduled jobs. Give only `php` a setting and the other two quietly run without it.
- **`zz-store.ini` sorts after `zz-kapelos.ini`**, which is why its values win.
- **Paths in this file are relative to Kapelos's folder**, so reach the store's files through `${MAGENTO_SRC}`.

### Add a fake of an outside service

Say the store sends orders to an ERP. You don't want your computer talking to the real one, so give the stack a fake that answers from files in the repository:

```yaml
# .kapelos/compose.yaml
services:
  erp:
    image: nginx:1.30
    volumes:
      - ${MAGENTO_SRC}/.kapelos/mocks/erp:/usr/share/nginx/html:ro
```

Each file under `.kapelos/mocks/erp/` is one answer. With `.kapelos/mocks/erp/orders/status.json` holding `{"status": "accepted"}`, a request for `http://erp/orders/status.json` gets exactly that.

The store reaches the fake at `http://erp/`, so point the store's ERP setting there, whatever your module calls it:

```bash
kapelos config:set acme_erp/api/base_url http://erp/
```

The same pattern works for a payment sandbox, a shipping-rate service or a search service. Use a real image for the service if one exists, and pin its version.

### Keep a queue consumer running

Turning cron on starts every consumer Magento has, along with every scheduled job. For one consumer on its own, say on a store whose scheduled jobs you don't want running, give it a service of its own:

```yaml
# .kapelos/compose.yaml
services:
  consumer-exports:
    image: ${COMPOSE_PROJECT_NAME:-kapelos}-php:${PHP_VERSION:-8.4}
    deploy:
      replicas: ${EXPORTS_CONSUMER:-0}
    working_dir: /app
    command: ["php", "bin/magento", "queue:consumers:start", "exportProcessor"]
    environment:
      SMTP_HOST: ${SMTP_HOST:-mailpit}
      SMTP_PORT: ${SMTP_PORT:-1025}
    volumes:
      - ${MAGENTO_SRC}:/app
      - type: bind
        source: ${KAPELOS_ENV_PHP:-${MAGENTO_SRC}/app/etc/env.php}
        target: /app/app/etc/env.php
        read_only: true
        bind:
          create_host_path: false
    depends_on:
      php:
        condition: service_healthy
    restart: unless-stopped
```

Turn it on for your site, then `kapelos up`:

```bash
# etc/sites/acme.env
EXPORTS_CONSUMER=1
```

I put three parts of it there on purpose:

- **`replicas` is the switch.** It's 0 unless the site says otherwise, so a teammate whose store isn't installed yet never gets a consumer that fails on start. Setting it back to 0 and running `kapelos up` stops it again.
- **The `env.php` line matters on an adopted store.** It runs the consumer with Kapelos's `env.php`, as the PHP containers are, rather than the store's own, which points at its real servers. On any other store it's the store's own file.
- **The mail settings** send anything it emails to the same place the store's PHP sends it.

It uses the PHP image Kapelos already built for the site, so there's nothing to download. `kapelos logs consumer-exports` follows it. While a snapshot is saved or restored the queue is paused, so the consumer stops and Docker restarts it until the queue is back.

### Trust it

`compose.yaml` and everything in `commands/` run with your permissions, so Kapelos runs them only after you've read them:

```bash
kapelos trust
```

That records their contents. Change any of them, or pull a change from a teammate, and Kapelos refuses to run them again until you've read the change and run `kapelos trust` again. `settings.env` needs no trust, because Kapelos checks every line of it.

## Your own commands

A command is an executable file. Put it in the store's `.kapelos/commands/` to share it with everyone on the store, or in `~/.config/kapelos/commands/` to have it in every store you work on.

### The ones Kapelos ships

`share/commands/` in the Kapelos folder holds working commands. Kapelos doesn't run them from there, and `kapelos commands` is what puts them where it does:

```bash
kapelos commands             # what there is, and where each one is installed
kapelos commands add         # all of them, into the store you're working on
kapelos commands add orders  # just that one
kapelos commands add --user  # into ~/.config/kapelos/commands, so they follow you into every store
kapelos commands remove      # take them out again
```

It brings each command's `lib/` files with it and takes them away again once nothing left names them, and it **trusts them for you when there's nothing else in `.kapelos` you haven't read**. A compose file or somebody else's command in the same folder means it won't, and it says so. **A file you've changed is left alone** by both `add` and `remove` until you say `-f`, because these are examples meant to be edited.

| Command | What it does |
|---|---|
| `orders` | Places real orders through the quote and `QuoteManagement::submit()`, a batch at a time, so there's something in the admin to look at and something for the queues to carry |
| `seed-grid` | Fills `sales_order_grid` with rows so the admin grid can be timed at a volume a real store reaches, and takes them out again |
| `profile` | Times the order grid, the dashboard or the product form, and prints the plan the database chose for each query |
| `mail` | Lists what the store has emailed and prints one message, without opening a browser |
| `indexers` | Every indexer's mode and state, and how many changed rows are waiting in its changelog |
| `big-tables` | The largest tables in the database, and which of them are only logs |
| `queue-depth` | How many messages are sitting in each RabbitMQ queue |

`orders` and `seed-grid` write to the store, so both refuse to run unless the site is `DISPOSABLE=yes`. `mail` and `queue-depth` read a JSON API, so both need `jq`.

They're meant to be changed. Read one, take the half you need, and make it yours: from then on `kapelos commands` reports it as `changed` and leaves it alone.

### How a command works

| | |
|---|---|
| **Name** | The file's name: `.kapelos/commands/smoke` is `kapelos smoke`. Lowercase letters, digits and dashes only |
| **Description** | The comment on the line under the shebang. `kapelos help` lists it |
| **Where it runs** | In the store's folder, on your machine |
| **What it gets** | Every setting of the active site as an environment variable (`MAGENTO_SRC`, `MAGENTO_BASE_URL`, `DISPOSABLE`, `STORES` and the rest), plus `KAPELOS`, the path to `kapelos` itself |
| **Arguments** | Everything after its name: `kapelos make-products 50` gives it `50` |
| **Its exit code** | Is `kapelos`'s exit code |
| **Which wins** | Kapelos's own commands can't be replaced. A store's command wins over one of yours with the same name |
| **Trust** | A store's commands run only once trusted. Yours never need it |

Inside a command, call Kapelos as `"$KAPELOS"`, never `kapelos`, so it works whether or not `kapelos` is on your `PATH`. Every `kapelos` command works there: `"$KAPELOS" cache:flush`, `"$KAPELOS" db`, `"$KAPELOS" snapshot save`.

Make the file executable before you commit it, and git keeps it that way for everyone:

```bash
chmod +x .kapelos/commands/smoke
```

### A first command: is everything up?

Asks every storefront and the admin for a page, and fails if any of them doesn't answer 200. Good after a deploy, an import or an upgrade.

```bash
#!/usr/bin/env bash
# Asks every storefront and the admin for a page, and fails unless each answers 200
set -euo pipefail

base="${MAGENTO_BASE_URL%/}"
scheme="${base%%://*}"
port=""
if [[ $base =~ :([0-9]+)$ ]]; then
  port=":${BASH_REMATCH[1]}"
fi

urls=("$base/" "$base/${MAGENTO_ADMIN_URI:-admin}/")
for pair in ${STORES:-}; do
  urls+=("$scheme://${pair%%=*}$port/")
done

failed=0
for url in "${urls[@]}"; do
  status="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 60 "$url" || true)"
  printf '%s  %s\n' "$status" "$url"
  [[ $status == 200 ]] || failed=1
done
exit "$failed"
```

```text
$ kapelos smoke
200  http://acme.test:8080/
200  http://acme.test:8080/admin/
200  http://outlet.test:8080/
```

`smoke` reads the site's own settings, so it checks the right addresses on every machine.

### A new teammate's first hour, in one command

A teammate clones the store, makes a site for it and runs `kapelos setup`. `setup` installs the packages, installs or upgrades the database, builds the front end and saves a snapshot to come back to.

```bash
#!/usr/bin/env bash
# Gets a fresh clone to a working store: packages, database, front end and a clean snapshot
set -euo pipefail

"$KAPELOS" composer install

if [[ -f app/etc/env.php ]]; then
  "$KAPELOS" setup:upgrade
else
  "$KAPELOS" magento-install
fi

if [[ -f package-lock.json ]]; then
  "$KAPELOS" npm ci
fi

if ! "$KAPELOS" snapshot | awk '{ print $1 }' | grep -qx clean; then
  "$KAPELOS" snapshot save clean
fi

echo "Ready. kapelos snapshot restore clean brings this state back."
```

The store's README then shrinks to five lines:

```bash
kapelos env acme              # then set MAGENTO_SRC in etc/sites/acme.env
kapelos use acme
kapelos up
kapelos trust
kapelos setup
```

### Replace real customers with made-up ones

A copy of a production database holds real people. Before you share a dump or take screenshots, replace them with made-up ones. This saves a snapshot first, so a mistake costs nothing:

```bash
#!/usr/bin/env bash
# Replaces customers' names, emails and addresses with made-up ones, after saving a snapshot
set -euo pipefail

name="before-anonymise-$(date +%Y%m%d-%H%M%S)"
"$KAPELOS" snapshot save "$name"

"$KAPELOS" db <<'SQL'
UPDATE customer_entity
   SET email = CONCAT('customer', entity_id, '@example.test'),
       firstname = 'Test', lastname = CONCAT('Customer ', entity_id)
 WHERE email NOT LIKE '%@example.test';

UPDATE customer_address_entity
   SET firstname = 'Test', lastname = 'Customer', street = '1 Test Street',
       telephone = '0000000000'
 WHERE street <> '1 Test Street';

UPDATE sales_order
   SET customer_email = CONCAT('order', entity_id, '@example.test'),
       customer_firstname = 'Test', customer_lastname = 'Customer'
 WHERE customer_email NOT LIKE '%@example.test';

UPDATE sales_order_address
   SET email = CONCAT('order', parent_id, '@example.test'),
       firstname = 'Test', lastname = 'Customer', street = '1 Test Street',
       telephone = '0000000000'
 WHERE street <> '1 Test Street';

UPDATE sales_order_grid
   SET customer_email = CONCAT('order', entity_id, '@example.test'),
       customer_name = 'Test Customer', billing_name = 'Test Customer',
       shipping_name = 'Test Customer', billing_address = '1 Test Street',
       shipping_address = '1 Test Street'
 WHERE customer_email NOT LIKE '%@example.test';

UPDATE quote
   SET customer_email = CONCAT('quote', entity_id, '@example.test'),
       customer_firstname = 'Test', customer_lastname = 'Customer'
 WHERE customer_email NOT LIKE '%@example.test';

UPDATE quote_address
   SET email = CONCAT('quote', quote_id, '@example.test'),
       firstname = 'Test', lastname = 'Customer', street = '1 Test Street',
       telephone = '0000000000'
 WHERE street <> '1 Test Street';

UPDATE newsletter_subscriber
   SET subscriber_email = CONCAT('subscriber', subscriber_id, '@example.test')
 WHERE subscriber_email NOT LIKE '%@example.test';
SQL

"$KAPELOS" indexer:reindex customer_grid
"$KAPELOS" cache-reset
echo "Done. kapelos snapshot restore $name puts the originals back."
```

Each `WHERE` skips rows already replaced, so running the command twice changes nothing the second time. Each run saves a snapshot of its own; `kapelos snapshot` lists them and `kapelos snapshot delete` clears old ones.

**The command is a starting point, not a complete list.** It covers customers, their addresses, orders, the order grid, shopping carts and newsletter subscribers. The invoice, shipment and credit memo grids hold names too, and so does any extension that stores people in its own tables, such as reviews or loyalty. Add those for your store, and add the table prefix to each name if the store uses one.

### Run PHP inside the store

`"$KAPELOS" shell` reads a script from its input when it isn't given a terminal, so a command can run anything in the PHP container. Keep the PHP in a folder inside `commands/`: it's covered by trust like the commands, and `kapelos` doesn't mistake it for one.

This one makes test products with made-up names and prices, for a catalogue to try things against:

```bash
#!/usr/bin/env bash
# Makes COUNT simple products with made-up names and prices: kapelos make-products [COUNT]
set -euo pipefail

count="${1:-20}"
if [[ ! $count =~ ^[0-9]+$ ]]; then
  echo "usage: kapelos make-products [COUNT]" >&2
  exit 2
fi

"$KAPELOS" shell <<<"php .kapelos/commands/lib/make-products.php $count"
"$KAPELOS" indexer:reindex
```

```php
<?php
// .kapelos/commands/lib/make-products.php
declare(strict_types=1);

use Magento\Catalog\Api\Data\ProductInterfaceFactory;
use Magento\Catalog\Api\ProductRepositoryInterface;
use Magento\Catalog\Model\Product\Attribute\Source\Status;
use Magento\Catalog\Model\Product\Type;
use Magento\Catalog\Model\Product\Visibility;
use Magento\Framework\App\Area;
use Magento\Framework\App\Bootstrap;
use Magento\Framework\App\State;
use Magento\Framework\Exception\NoSuchEntityException;

require '/app/app/bootstrap.php';

function productExists(ProductRepositoryInterface $products, string $sku): bool
{
    try {
        $products->get($sku);
        return true;
    } catch (NoSuchEntityException) {
        return false;
    }
}

$objectManager = Bootstrap::create(BP, $_SERVER)->getObjectManager();
$objectManager->get(State::class)->setAreaCode(Area::AREA_ADMINHTML);
$products = $objectManager->get(ProductRepositoryInterface::class);
$factory = $objectManager->get(ProductInterfaceFactory::class);

$count = (int) ($argv[1] ?? 20);
for ($number = 1; $number <= $count; $number++) {
    $sku = sprintf('TEST-%04d', $number);
    if (productExists($products, $sku)) {
        continue;
    }
    $product = $factory->create()
        ->setSku($sku)
        ->setName(sprintf('Test product %d', $number))
        ->setAttributeSetId(4)
        ->setTypeId(Type::TYPE_SIMPLE)
        ->setPrice(random_int(500, 20000) / 100)
        ->setVisibility(Visibility::VISIBILITY_BOTH)
        ->setStatus(Status::STATUS_ENABLED)
        ->setWebsiteIds([1])
        ->setStockData(['qty' => 100, 'is_in_stock' => 1]);
    $products->save($product);
    echo $sku, PHP_EOL;
}
```

Products `make-products` already made are skipped, so `kapelos make-products 50` after `kapelos make-products 20` adds thirty. Attribute set 4 is Magento's default one.

### Build a theme with Node

A theme with its own Tailwind build, such as a Hyvä child theme, keeps its `package.json` inside the theme. `npm --prefix` runs it there:

```bash
#!/usr/bin/env bash
# Builds the theme's styles, then empties the page cache: kapelos theme [watch]
set -euo pipefail

theme=app/design/frontend/Acme/default/web/tailwind

if [[ ${1:-} == watch ]]; then
  exec "$KAPELOS" npm --prefix "$theme" run watch
fi

"$KAPELOS" npm --prefix "$theme" ci
"$KAPELOS" npm --prefix "$theme" run build-prod
"$KAPELOS" cache:clean full_page
```

### A command in another language

A command only has to be executable, so any language your machine has will do. This one is Python, and gets its numbers from `"$KAPELOS" db`:

```python
#!/usr/bin/env python3
# Counts the catalogue's products by type
import os
import subprocess

query = """
    SELECT type_id, COUNT(*) FROM catalog_product_entity
    GROUP BY type_id ORDER BY 2 DESC
"""
result = subprocess.run(
    [os.environ["KAPELOS"], "db"],
    input=query,
    capture_output=True,
    text=True,
    check=True,
)
for line in result.stdout.splitlines()[1:]:
    product_type, count = line.split("\t")
    print(f"{product_type:<14}{count:>8}")
```

```text
$ kapelos make-products 20
$ kapelos catalog-stats
simple              20
```

`catalog-stats` runs on your machine, not in a container, so it can use whatever your machine has installed.

### Commands just for you

Commands in `~/.config/kapelos/commands/` work in every store and need no trust, because you wrote them. This one opens the store, the admin or the mail catcher:

```bash
#!/usr/bin/env bash
# Opens the store, the admin or the mail catcher in your browser: kapelos open [admin|mail]
set -euo pipefail

case "${1:-store}" in
  store) url="$MAGENTO_BASE_URL" ;;
  admin) url="${MAGENTO_BASE_URL%/}/${MAGENTO_ADMIN_URI:-admin}/" ;;
  mail) url="http://127.0.0.1:${MAIL_UI_PORT:-8025}/" ;;
  *)
    echo "usage: kapelos open [store|admin|mail]" >&2
    exit 2
    ;;
esac

if command -v xdg-open >/dev/null; then
  xdg-open "$url"
else
  open "$url"
fi
```

And a start-of-day one, which brings the site up and tells you what state it's in:

```bash
#!/usr/bin/env bash
# Starts the active site and says what state it's in
set -euo pipefail

"$KAPELOS" up
"$KAPELOS" cron
"$KAPELOS" snapshot
if [[ -e .git ]]; then
  git status --short --branch
fi
```

They need an active site, since their settings come from it.

### Writing one without trusting it every time you save

Every change to a store's command means another `kapelos trust`. While you're still writing one, keep it in `~/.config/kapelos/commands/`, where nothing needs trusting. When it works, move it into the store's `.kapelos/commands/`, trust it once and commit it.

## Scripting Kapelos

### Exit codes and questions

Every command exits 0 when it worked and non-zero when it didn't, so `&&` and `set -e` work as you'd expect. `site audit`, `doctor`, `test` and your own `smoke` exit 1 on a failure.

Commands that would destroy something ask first. With no terminal to ask on, such as in a script or a hook, they refuse rather than guess. `-y` answers yes:

```bash
kapelos snapshot restore clean -y
kapelos cron on -y
kapelos site remove old-demo -y
```

### Check another site without switching

`KAPELOS_ENV` names a settings file for one command, relative to Kapelos's folder. To see another site's addresses and passwords while you're on this one:

```bash
KAPELOS_ENV=etc/sites/shop2.env kapelos info
```

`KAPELOS_ENV` doesn't switch the active site, and commands that need a site running still need it running. `kapelos site audit shop2` takes the site's name instead.

### Run the tests before every push

In the store's repository, as `.git/hooks/pre-push`, made executable:

```bash
#!/usr/bin/env bash
# Runs the unit tests before anything leaves this machine.
exec kapelos test unit
```

The stack has to be running for the tests to run, so a push with the stack down is refused too. `git push --no-verify` skips the hook when you mean to.

### Audit a store every week

A line for `crontab -e`. Cron starts with an almost empty `PATH`, so give the full path:

```text
0 8 * * 1  /home/you/kapelos/bin/kapelos site audit acme > /home/you/acme-audit.txt 2>&1
```

The report is the file. The advisories refresh themselves once a day, so a new vulnerability in something the store uses shows up the Monday after it's published.

### Rehearse an upgrade you can undo

Snapshots and git together make an upgrade safe to try:

```bash
kapelos snapshot save before-upgrade
git switch -c upgrade-2.4.9

kapelos composer require magento/product-community-edition:2.4.9 --no-update
kapelos composer update
kapelos setup:upgrade
kapelos smoke
kapelos test
```

`etc/magento-versions.tsv` lists the service versions the new release supports. Set them in the site's settings, run `kapelos up`, and `kapelos doctor` confirms the site matches.

If it didn't work out, go back to where you were:

```bash
git switch -
kapelos composer install
kapelos snapshot restore before-upgrade -y
```

If you changed service versions, put them back before the restore, since the snapshot's database was written by the old MariaDB.
