# Kapelos

[![check](https://github.com/kingletas/kapelos/actions/workflows/check.yml/badge.svg)](https://github.com/kingletas/kapelos/actions/workflows/check.yml)
[![licence: MIT](https://img.shields.io/badge/licence-MIT-blue.svg)](LICENSE)

A Docker Compose stack for working on a Magento 2 store. Point Kapelos at your Magento folder, or let it download one, and you get everything the store needs to run: PHP, nginx, Varnish, MariaDB, OpenSearch, RabbitMQ, two Valkey caches and a mail catcher, with Traefik in front for HTTPS and Xdebug.

Your code stays where it is. Kapelos mounts it into the containers, so an edit in your editor is live in the store straight away.

A *kapelos* was the small shopkeeper of an ancient Greek town. His bigger sibling is [Emporion](https://github.com/kingletas/emporion), the harbour trading post, which runs Magento on Kubernetes or Compose with many stores side by side. If you need that, use Emporion. If you need one store running on your computer by lunchtime, stay here.

## Contents

- [What you need](#what-you-need)
- [Three ways to start](#three-ways-to-start)
- [Everyday commands](#everyday-commands)
- [Finding things](#finding-things)
- [How Kapelos is laid out](#how-kapelos-is-laid-out)
- [Settings](#settings)
- [Several projects](#several-projects)
- [Running a store you already have](#running-a-store-you-already-have)
- [A store's own settings](#a-stores-own-settings)
- [Several storefronts](#several-storefronts)
- [Mail](#mail)
- [Magento commands](#magento-commands)
- [Cron and queue consumers](#cron-and-queue-consumers)
- [Node, npm and grunt](#node-npm-and-grunt)
- [The Kingletas modules](#the-kingletas-modules)
- [Emptying every cache](#emptying-every-cache)
- [Snapshots and dumps](#snapshots-and-dumps)
- [Rehearsing a deployment](#rehearsing-a-deployment)
- [Running the store's tests](#running-the-stores-tests)
- [Auditing a site](#auditing-a-site)
- [Driving the store with bluetir and drexbot](#driving-the-store-with-bluetir-and-drexbot)
- [Bundling JavaScript with manipulus](#bundling-javascript-with-manipulus)
- [Running the store's CI](#running-the-stores-ci)
- [HTTPS](#https)
- [Xdebug](#xdebug)
- [Full-page caching with Varnish](#full-page-caching-with-varnish)
- [Behind your own reverse proxy](#behind-your-own-reverse-proxy)
- [Additions only your machine needs](#additions-only-your-machine-needs)
- [Mac and Windows](#mac-and-windows)
- [Checking your setup](#checking-your-setup)
- [Testing Kapelos itself](#testing-kapelos-itself)
- [What Kapelos doesn't do](#what-kapelos-doesnt-do)
- [Licence](#licence)

## What you need

- **Docker** with Compose v2. `docker compose version` should answer.
- **A Magento 2.4 store**, or nothing at all: `bin/kapelos demo` downloads one.
- **About 6 GB of free memory** while the stack runs.
- **On Linux, `vm.max_map_count` of at least 262144**, or OpenSearch won't start. `sysctl vm.max_map_count` shows it.

## Three ways to start

**A demo store, with no questions:**

```bash
git clone https://github.com/kingletas/kapelos && cd kapelos
bin/kapelos demo
```

That downloads [Mage-OS](https://mage-os.org), a community distribution of Magento that needs no account, into `var/stores/demo`, installs it with the [Kingletas modules](#the-kingletas-modules), and prints where everything is. The store is at <http://localhost:8080/>. Run `demo` again later and it starts the same demo without downloading anything.

**Your own setup, with a few questions first:**

```bash
bin/kapelos interactive
```

Kapelos asks for a name, where the code comes from (Mage-OS, Magento Open Source with your Marketplace keys, or a folder you already have), the hostname, whether you want trusted HTTPS, and whether to add sample products. Then it does the rest without asking again.

**By hand**, when you want to see every step:

```bash
bin/kapelos env
```

That writes `.env` with a random password for everything that needs one. Set `MAGENTO_SRC` in it to your Magento folder, then:

```bash
bin/kapelos up
bin/kapelos magento-install
```

The store answers at the `MAGENTO_BASE_URL` in `.env`, which is `http://magento.test:8080/` unless you change it. Add `127.0.0.1 magento.test` to `/etc/hosts` so that name reaches your machine. [From nothing to a storefront](docs/from-nothing.md) walks through this path one step at a time.

## Everyday commands

Everything goes through one command, `bin/kapelos`. Run it on its own for the full list.

| Command | What it does |
|---|---|
| `bin/kapelos up` | Start everything and wait until the store can serve. Run `up` again after changing `.env` |
| `bin/kapelos info` | Every address, port and login. See [Finding things](#finding-things) |
| `bin/kapelos down` | Stop everything. The database and search index are kept |
| `bin/kapelos restart php` | Restart a service, after editing its file in `etc/` |
| `bin/kapelos ps` | What's running, and whether it's healthy |
| `bin/kapelos logs php` | Follow the logs, of one service or all of them |
| `bin/kapelos shell` | A shell in the PHP container, at the Magento root |
| `bin/kapelos cache:flush` | Any Magento command. See [Magento commands](#magento-commands) |
| `bin/kapelos cache-reset` | Empty Magento's cache, Valkey and Varnish in one go |
| `bin/kapelos debug cache:flush` | Run a Magento command with Xdebug, connected to your IDE |
| `bin/kapelos cert` | Issue a trusted HTTPS certificate with mkcert |
| `bin/kapelos deploy` | Rehearse a production deployment. `bin/kapelos develop` goes back |
| `bin/kapelos composer install` | Run Composer |
| `bin/kapelos db` | A MariaDB prompt on the store's database. `db dump` writes a gzipped dump |
| `bin/kapelos snapshot save clean` | Save the database, search and queue; `snapshot restore clean` puts them back. See [Snapshots and dumps](#snapshots-and-dumps) |
| `bin/kapelos cron on` | Run Magento's scheduled jobs and queue consumers. See [Cron and queue consumers](#cron-and-queue-consumers) |
| `bin/kapelos npm install` | npm, npx or grunt at the store's root. See [Node, npm and grunt](#node-npm-and-grunt) |
| `bin/kapelos doctor` | Check this machine and this site. See [Checking your setup](#checking-your-setup) |
| `bin/kapelos valkey cache` | `valkey-cli` on the cache. `valkey session` for sessions |
| `bin/kapelos test` | The store's PHPUnit tests. See [Running the store's tests](#running-the-stores-tests) |
| `bin/kapelos use acme` | Switch to another project. See [Several projects](#several-projects) |
| `bin/kapelos site remove acme` | Delete a site's containers, database, snapshots and files |
| `bin/kapelos modules` | The Kingletas modules. See [The Kingletas modules](#the-kingletas-modules) |
| `bin/kapelos site audit` | Vulnerable dependencies, credentials and unsafe settings. See [Auditing a site](#auditing-a-site) |
| `bin/kapelos bluetir`, `bin/kapelos drexbot` | Browser tests against the store. See [Driving the store](#driving-the-store-with-bluetir-and-drexbot) |
| `bin/kapelos ci` | The store's GitHub Actions workflows, run here with act. See [Running the store's CI](#running-the-stores-ci) |

Kapelos works from any directory. To type `kapelos` without the `bin/`, put it on your `PATH`:

```bash
make install                         # into ~/bin
make install PREFIX=~/.local/bin     # or wherever you keep commands
```

That writes a small `kapelos` command that runs this folder's `bin/kapelos`. Kapelos keeps every site, store and snapshot in this folder, so the folder stays where it is: update it with `git pull`, and if you ever move it, run `make install` again from the new place. The command says so if you forget. `make install` won't overwrite a `kapelos` it didn't put there, and it tells you if another `kapelos` comes first on your `PATH`. `make uninstall` takes the command away and leaves every site as it was.

If you prefer make, every command is also a target: `make up`, `make restart ARGS=php`, `make magento ARGS="cache:flush"`.

[Examples](docs/examples.md) puts these to work: a recipe for each everyday task, then a store's own stack and commands of your own.

## Finding things

`bin/kapelos info` lists everything you might go looking for. `demo` and `interactive` print it when they finish. Here's what the demo shows, with the generated passwords left out:

```text
  Site         kapelos-demo, running. Settings in ./etc/sites/demo.env
  Code         /home/you/kapelos/var/stores/demo

  Store        http://localhost:8080/
  Admin        http://localhost:8080/admin
               user admin, password …
  HTTPS        https://localhost:8443/  (Traefik's own self-signed certificate, until kapelos cert)
  Mail         http://127.0.0.1:8025  (every email the store sends lands here)

  Database     127.0.0.1:13306, database magento
               user magento, password …  ·  root password …
               or a prompt: kapelos db
  Valkey       kapelos valkey cache  ·  kapelos valkey session   (not published outside the stack)
  OpenSearch   http://127.0.0.1:9200
  RabbitMQ     http://127.0.0.1:15672  user magento, password …

  Xdebug       listen on port 9003, and map /app to /home/you/kapelos/var/stores/demo
               the browser extension's cookie or ?XDEBUG_TRIGGER=1 sends a request to the debugging PHP
```

A few you'll reach for often:

```bash
bin/kapelos db                           # a MariaDB prompt
bin/kapelos db < query.sql               # run a file of SQL
bin/kapelos valkey cache KEYS '*'        # look inside the cache
bin/kapelos valkey session DBSIZE        # how many sessions there are
```

## How Kapelos is laid out

The folders follow the usual Linux split between programs, settings and packages:

| Folder | What's in it |
|---|---|
| `bin/` | `kapelos`: the settings every part reads, the list of commands, and the dispatch that picks one |
| `lib/` | The rest of it, a file per job, sourced by `bin/kapelos` at startup. `core.sh` holds the settings, trust and container helpers the others build on; then `sites.sh`, `store.sh`, `adopt.sh`, `stack.sh`, `checks.sh`, `tools.sh`, `commands.sh` and `selftest.sh` |
| `etc/` | The settings the containers read: `traefik/`, `nginx/`, `varnish/`, `mariadb/` and `php/`. Edit one and run `bin/kapelos restart <service>`. No rebuild needed. `etc/tls/` holds the certificate `bin/kapelos cert` issues, and `etc/sites/` holds one settings file per project |
| `opt/php/`, `opt/audit/`, `opt/bluetir/`, `opt/drexbot/` | The images Kapelos builds: PHP, the audit tools, and the two browser suites. manipulus is built from its own Dockerfile on GitHub. The other services use stock images |
| `var/stores/` | The stores Kapelos downloads for you, such as the demo. Ignored by git |
| `share/commands/` | Working [commands of your own](docs/examples.md#your-own-commands) to use and change: place test orders, fill the order grid, time an admin page, read the mail the store sent, and more. `bin/kapelos commands add` installs them into a store |
| `scripts/` | What `make install` and `make uninstall` run, and the check that proves them |
| `docs/` | [From nothing to a storefront](docs/from-nothing.md), and [Examples](docs/examples.md): recipes for every command, a store's own `.kapelos` folder and commands of your own |

`compose.yaml` and `.env.example` sit at the top, where Docker Compose looks for them.

## Settings

Everything lives in `.env`, or in the active site's file if you use [several projects](#several-projects). The ones you're most likely to change:

| Setting | Default | What it's for |
|---|---|---|
| `MAGENTO_SRC` | *(none)* | The Magento tree to run. Required |
| `MAGENTO_BASE_URL` | `http://magento.test:8080/` | Where the store answers. Used by `bin/kapelos magento-install` |
| `HTTP_PORT` | `8080` | The port the store answers on over HTTP |
| `HTTPS_PORT` | `8443` | The port it answers on over HTTPS. See [HTTPS](#https) |
| `DB_PORT` | `13306` | MariaDB, for a database tool on your machine |
| `OPENSEARCH_PORT`, `RABBITMQ_UI_PORT`, `MAIL_UI_PORT` | `9200`, `15672`, `8025` | OpenSearch, RabbitMQ's management page and Mailpit, on your machine |
| `XDEBUG_MODE` | `debug` | What Xdebug does in the debugging container. See [Xdebug](#xdebug) |
| `DISPOSABLE` | `no` | `yes` lets bluetir and drexbot place orders and register accounts. `demo` and `interactive` set it |
| `STORES` | *(none)* | Other storefronts by hostname. See [Several storefronts](#several-storefronts) |
| `CRON` | `no` | `yes` runs Magento's scheduled jobs. See [Cron and queue consumers](#cron-and-queue-consumers) |
| `DEPLOY_LOCALES` | `en_US` | The languages `bin/kapelos deploy` builds static files for, separated by spaces |
| `PHP_VERSION` | `8.4` | And one `*_VERSION` per service, `NODE_VERSION` included. The defaults are what the newest Magento release supports, and `etc/magento-versions.tsv` lists the versions for each release: `adopt` uses the store's row and `doctor` checks against it. `OPENSEARCH_VERSION` is a full release, such as `3.6.0`, because OpenSearch publishes no minor tags |
| `COMPOSE_FILE` | `compose.yaml` | Which layers make up the stack |
| `COMPOSE_PROFILES` | `mail` | Remove `mail` to leave out the bundled Mailpit |

Everything binds to `127.0.0.1`, so nothing is reachable from your network. [SECURITY.md](SECURITY.md) explains what changes if you open that up.

## Several projects

Each project is a **site**: a settings file in `etc/sites/` with its own code folder, database, search index and caches. Nothing is shared between two sites.

```bash
bin/kapelos env acme          # writes etc/sites/acme.env; set MAGENTO_SRC in it
bin/kapelos use acme          # stops whichever site is running, and switches to acme
bin/kapelos up
bin/kapelos sites             # lists them, with a * on the active one
```

`demo`, `interactive` and `adopt` make sites too, so they sit in the same list. They never stop a site that's running: they say which one is, and leave switching to you.

`bin/kapelos site remove acme` deletes a site: its containers, database, search index, snapshots and the files Kapelos keeps for it. Kapelos lists everything first and asks you to type the site's name. The store's code stays where it is, unless Kapelos downloaded it into `var/stores/`.

**One site runs at a time, and I built Kapelos that way on purpose.** A Magento stack wants several gigabytes of memory, and your computer is for the project in front of you. Switching is cheap instead: `use` stops the running site with its data kept, and the next `up` brings the other one back exactly as you left it. `up` refuses to start a second site while one is running, and says which. If you need several stores running side by side, that's what [Emporion](https://github.com/kingletas/emporion) is for.

`.env` becomes a link to the active site's file, so `bin/kapelos`, `make` and plain `docker compose` always agree about which project they're working on. If you had a `.env` of your own, the first `use` turns it into a site called `default`, with nothing lost.

## Running a store you already have

There are two ways, and they differ in what they're allowed to change.

- **`adopt` runs the store as it is.** Its code stays where it lives, its database is copied, and neither its code nor its settings are rewritten. Like any running store, it writes logs and cache files into its `var/` folder. Use it for a store that another stack also runs, or one you want to see exactly as it is.
- **`import` and `connect` make it a Kapelos development store.** They rewrite its `app/etc/env.php`, put it in developer mode and upgrade its database.

### Adopting a store

```bash
bin/kapelos adopt ~/projects/acme --datadir ~/projects/acme-db
bin/kapelos adopt ~/projects/acme --dump ~/Downloads/acme.sql.gz --name acme --url http://acme.test:8080/
```

`--datadir` copies a MariaDB data directory, the folder a database server keeps its files in. It's the fast way for a large database, because copying its files is far quicker than loading a dump. Stop the server that uses it first. `--dump` loads a `.sql` or `.sql.gz` file instead.

What `adopt` does:

- **Kapelos reads what the store is**: Magento edition and version, its mode, the PHP versions its `composer.json` allows, and the MariaDB version that wrote the data directory. It builds this site with the newest PHP the store allows, and runs the same MariaDB.
- **Kapelos copies the database and never opens the original.** The copy gets this site's own logins; everything else in it is left as it was.
- **Kapelos leaves the store's `app/etc/env.php` alone.** It writes its own version in `var/sites/<site>/env.php` and lays it over the original inside the containers, so another stack can keep using the folder. That version points the store at this stack's database, caches, queue, Varnish and search, and pins its addresses, so the copied database doesn't need changing either. Everything else the store sets stays, encryption key included.
- **Kapelos sends the store's mail to Mailpit.** An adopted store usually holds real customers, so it's pinned to PHP's own mail sending, which Kapelos catches. A third-party mail extension with its own server setting isn't covered; switch it off if you have one.
- **Kapelos keeps the store's mode, compiled code and static files.** A production store stays in production mode and nothing is compiled or deployed. If the database is behind the code, `adopt` says so and leaves it: in production mode `setup:upgrade` clears the compiled code.
- **Kapelos declares the store's queues in RabbitMQ, which starts empty.** Magento declares its exchanges and queues only during `setup:upgrade`, which `adopt` skips on a production store and on any store whose database is up to date. Without them, queue consumers stop with `NOT_FOUND`, and a message the store publishes, such as a mass attribute update, is dropped without an error. So `adopt` runs only the part of `setup:upgrade` that declares them, and checks every queue the store's configuration names is there. `bin/kapelos queues` does the same on any site.
- **Kapelos names every extension encoded with SourceGuardian, and whether it loads here.** It turns on SourceGuardian for the site, then tries one file from each and prints the loader's own answer, so you know which extensions will fail before a page does.
- **Kapelos marks the site `DISPOSABLE=no`**, so bluetir won't place orders in it.
- **Kapelos asks every address for its page and its theme's stylesheet, and the admin for its login page**, and prints what each answered. `adopt` fails if any of these checks, or the queue check, doesn't pass.

More than one storefront: `--store second.test=second_store` sends that hostname to the store view with that code, and `adopt` checks the code exists in the database. It's saved as the site's `STORES`; see [Several storefronts](#several-storefronts).

**Service versions come from the store's release.** `adopt` reads which Magento release the store is, or for Mage-OS which Magento release it's built on, and runs the MariaDB, OpenSearch, Valkey, RabbitMQ, Varnish and nginx versions `etc/magento-versions.tsv` lists for it. A data directory's own MariaDB version wins over the table.

An address with no port, such as `https://acme.test/`, has to come through a reverse proxy: name its Docker network with `--proxy`. See [Behind your own reverse proxy](#behind-your-own-reverse-proxy).

**The search index starts empty, so `adopt` builds it.** `--no-reindex` skips it and prints the commands to run later.

**To remove an adopted site**, which deletes the copy and nothing else: `bin/kapelos site remove <site>`.

### Importing and connecting

```bash
bin/kapelos env acme          # then set MAGENTO_SRC in etc/sites/acme.env to the store's folder
bin/kapelos use acme
bin/kapelos up
bin/kapelos import ~/Downloads/acme.sql.gz
bin/kapelos connect
```

- `import` loads a `.sql` or `.sql.gz` dump. It refuses if the database already has tables, so it can never pour one store into another. It also strips the `DEFINER` clauses dumps carry from their old server, which would stop the import otherwise.
- `connect` points the store at Kapelos. It rewrites `app/etc/env.php` for this stack's database, caches, queue, Varnish, search and mail, every database connection included, and swaps a production lock server or remote storage for local ones. It keeps the encryption key, so encrypted settings from the dump still work. It sets every store's address to `MAGENTO_BASE_URL`, including addresses pinned in `env.php`, clears the cache files the store arrived with, upgrades the database if the code is newer, and rebuilds the search index. That last step is slow on a big catalogue, because the index starts empty here.
- **The admin logins are the ones from the dump.** To make one of your own: `bin/kapelos admin:user:create`.

`bin/kapelos interactive` does all of this for you when you choose "A folder I already have".

`magento-install` refuses a database that already has tables for the same reason, and says so.

If your store ships its own nginx configuration instead of Magento's `nginx.conf.sample`, set `MAGENTO_NGINX_CONF` to its path inside the container, for example `/app/nginx.conf`.

## A store's own settings

A store can carry its Kapelos settings in its own repository, in a `.kapelos` folder at its root, so everyone who works on it gets the same stack.

```text
.kapelos/
├── settings.env     facts about the store: service versions, its nginx rules, its storefronts
├── compose.yaml     services or changes the store needs, merged over Kapelos's own
└── commands/        your own commands: .kapelos/commands/reindex-feeds is kapelos reindex-feeds
```

**Kapelos ships working commands to start from.** `bin/kapelos commands add` puts all of them in this store's `.kapelos/commands/`, with their helper files, and trusts them when there's nothing else in `.kapelos` you haven't read. `--user` puts them in `~/.config/kapelos/commands/` instead, where they follow you into every store. [Your own commands](docs/examples.md#your-own-commands) has the details.

**`settings.env` may set only facts about the store**: `PHP_VERSION`, `NODE_VERSION` and the other `*_VERSION` settings, `INSTALL_SOURCEGUARDIAN`, `MAGENTO_NGINX_CONF`, `STORES`, `DEPLOY_LOCALES`, `MANIPULUS_THEME` and `AUDIT_PATHS`. It wins over the site's settings for those. It can't open ports, change passwords or name a folder on your machine, and Kapelos refuses the whole file, naming the line, if it tries. `MAGENTO_NGINX_CONF` has to be inside the store, such as `/app/.kapelos/nginx.conf`, which is how a store brings the nginx rules its own server runs.

```bash
# .kapelos/settings.env
PHP_VERSION=8.3
MAGENTO_NGINX_CONF=/app/.kapelos/nginx.conf
STORES="second.test=second_store"
```

**`compose.yaml` and `commands/` run with your permissions, so they run only once you've trusted them.** The first time a store brings either, and every time either changes, Kapelos stops and asks you to read them:

```bash
bin/kapelos trust            # the active site's store, or: bin/kapelos trust ~/projects/acme
```

`compose.yaml` is merged over Kapelos's own files. Paths in it are relative to Kapelos's folder, so point at the store with `${MAGENTO_SRC}`. Kapelos adds it for every command it runs; plain `docker compose` doesn't know about it.

**A command is any executable file in `commands/`.** It runs from the store's root, with `KAPELOS` set to the `kapelos` command and the site's settings in its environment, so `"$KAPELOS" cache:flush` works inside it. The comment line under its shebang is its description in `bin/kapelos help`. Commands of your own for every store go in `~/.config/kapelos/commands/`. A command can't replace one of Kapelos's own.

## Several storefronts

A store with more than one storefront sends each hostname to its store view:

```bash
STORES="second.test=second_store third.test=third_store"
```

Set it in the site's settings or the store's `.kapelos/settings.env`, then:

```bash
bin/kapelos stores           # which store each hostname runs, and whether the database has it
bin/kapelos stores apply     # sets each store's address, with MAGENTO_BASE_URL's scheme and port
```

nginx tells Magento which store to run, and every other hostname runs the default. Behind a reverse proxy, every hostname in `STORES` is also sent to the proxy, unless `PROXY_HOSTS` says otherwise. Each hostname needs to reach your machine, through `/etc/hosts` or your own DNS.

## Mail

Every email the store sends goes to Mailpit, a mail catcher that keeps it instead of delivering it. Read it at <http://127.0.0.1:8025>.

If you already run a mail catcher, remove `mail` from `COMPOSE_PROFILES`, point `SMTP_HOST` and `SMTP_PORT` at yours, then run `bin/kapelos down` and `bin/kapelos up`. `up` alone leaves Mailpit running.

## Magento commands

Type any Magento command straight after `bin/kapelos`. It runs in the PHP container, at the Magento root, as your user:

```bash
bin/kapelos cache:clean
bin/kapelos setup:upgrade
bin/kapelos indexer:reindex
bin/kapelos c:f
```

The last one works because Magento accepts any unambiguous abbreviation, so `c:f` is `cache:flush`.

`bin/kapelos magento` is the long form. You need it only for a Magento command without a colon, such as `bin/kapelos magento list`. Kapelos's own commands never have a colon, so the two never clash.

If the stack isn't running, you get `php isn't running. Start the stack with: kapelos up`, not a Docker error.

### Changing the module list on a deployed store

`module:enable`, `module:disable`, `module:uninstall`, `setup:upgrade` and `deploy:mode:set` all
empty `generated/`, and a deployed store's class map names the classes that were in there. Composer
trusts a class map without checking, so without help those commands stop on a warning about a
missing `Proxy` class, which says nothing about the cause, and on a production store `module:disable`
would fail without writing `app/etc/config.php` at all: it looked like it ran, and nothing changed.

Kapelos clears the generated code and rebuilds the class map plain before running one of those, so
the command does its work, and reminds you to compile afterwards:

```
==> This command clears generated code, so clearing it first and rebuilding the class map plain
The following modules have been disabled:
- Vendor_Module
==> Generated code is empty and the store is in production mode. Compile it: kapelos setup:di:compile
```

Any Magento command repairs a class map it finds already in that state, whatever left it there, and
`kapelos doctor` reports it.

## Cron and queue consumers

Magento's scheduled jobs don't run until you turn them on, because on a store you brought they use its real settings: its feeds, exports and emails to outside servers.

```bash
bin/kapelos cron on          # runs cron:run every minute, which also starts the queue consumers
bin/kapelos cron             # whether it's on, and what ran in the last hour
bin/kapelos cron run         # one run, now
bin/kapelos cron off
```

On a site that isn't `DISPOSABLE=yes`, `cron on` says what that means and asks first; `-y` skips the question.

A consumer needs its queue to exist in RabbitMQ. `setup:upgrade` and `adopt` declare the queues. `bin/kapelos queues` declares them on any site without the rest of `setup:upgrade`, so it's safe on a production store, and says how many of the store's queues are there.

## Node, npm and grunt

Node runs in its own container at the store's root, only while a command runs:

```bash
bin/kapelos npm install
bin/kapelos npx tailwindcss --help
bin/kapelos grunt watch      # Magento's grunt, with LiveReload on port 35729
```

`NODE_VERSION` picks the version, and npm's download cache lives in `var/npm-cache`. Magento's own grunt setup starts from its sample files: copy `package.json.sample` and `Gruntfile.js.sample` without the `.sample`, then `bin/kapelos npm install`.

## The Kingletas modules

Kapelos can put five Magento modules into a store, straight from their GitHub repositories:

| Module | What it does | See what it's doing |
|---|---|---|
| [catalog-access](https://github.com/kingletas/magento2-module-catalog-access) | The catalogue reads every module ends up writing, done once and done right | |
| [promotion-access](https://github.com/kingletas/magento2-module-promotion-access) | The same for cart price rules | |
| [process-guard](https://github.com/kingletas/magento2-module-process-guard) | Budgets, reporting and a kill switch for the busiest paths, such as placing an order | `bin/kapelos kingletas:process-guard:policies` |
| [section-policy](https://github.com/kingletas/magento2-module-section-policy) | Decides what each private-content refresh actually refreshes, and what it costs | `bin/kapelos kingletas:section-policy:report` |
| [cache-vary](https://github.com/kingletas/magento2-module-cache-vary) | Decides what the full-page-cache key is made of, and how many copies of each page that allows | `bin/kapelos kingletas:cache-vary:policy` |

```bash
bin/kapelos modules                          # which are installed and enabled
bin/kapelos modules add                      # all five
bin/kapelos modules add process-guard        # or just one
bin/kapelos modules remove                   # take them out again
```

`demo` adds all five, and `interactive` asks. Kapelos never adds them to a store you brought yourself unless you run `modules add`.

`add` puts their repositories in the store's `composer.json`, runs `composer require`, enables them and runs `setup:upgrade`. `remove` undoes each of those steps, down to taking the repositories back out when nothing of theirs is left. The list lives in `etc/modules.tsv`.

## Emptying every cache

```bash
bin/kapelos cache-reset
```

This empties the three places a stale page can hide, in this order:

1. **Magento's cache**, with `cache:flush`.
2. **Valkey's cache instance**, which holds Magento's cache and full-page cache. It's emptied completely.
3. **Varnish**, where every cached page is banned, so the next request for each one goes to Magento.

**Sessions are kept.** They live in a separate Valkey instance, so you aren't logged out of the admin and don't lose a shopping cart.

`cache-reset` doesn't touch compiled code or static files. In developer mode Magento rebuilds those by itself when they're out of date.

## Snapshots and dumps

A snapshot saves the site's database, search index and queue, and puts them back in seconds, which beats reinstalling after a test that changed the store:

```bash
bin/kapelos snapshot save clean
bin/kapelos snapshot restore clean   # asks first; -y doesn't
bin/kapelos snapshot                 # lists them
bin/kapelos snapshot delete clean
```

Saving pauses the database, search and queue for as long as the copy takes, so the copy is consistent. Restoring replaces what's there, so save that first if you want it. Snapshots are Docker volumes on your machine and `site remove` deletes them with the site.

A dump is for taking a database somewhere else:

```bash
bin/kapelos db dump                  # var/dumps/<site>-<date>.sql.gz
bin/kapelos db import store.sql.gz   # the same as bin/kapelos import
```

A dump or snapshot of a store you brought holds its customers too. Dumps are written readable only by you.

## Rehearsing a deployment

```bash
bin/kapelos deploy
```

This runs the steps a production deployment runs, in the same order, on your tree:

1. Turn on maintenance mode.
2. `composer install --no-dev`, which removes the development packages from `vendor/`.
3. `setup:upgrade`, with the manipulus bundles module turned back on first if you've built one.
4. `setup:di:compile`.
5. Rebuild the autoloader's class map, now that the compiled classes exist.
6. `setup:static-content:deploy` for the languages in `DEPLOY_LOCALES`, then the manipulus bundles written again and their integrity hashes refreshed, if you use [manipulus](#bundling-javascript-with-manipulus).
7. Switch to production mode.
8. Empty every cache, as `cache-reset` does.
9. Turn off maintenance mode.

On a fresh store it takes me about a minute and a half. If a step fails, Kapelos stops there, tells you which step, and leaves the store in maintenance mode, the way a real deployment would.

**To go back to working on the store:**

```bash
bin/kapelos develop
```

That reinstalls the development packages, switches to developer mode, which clears the compiled code and static files, turns maintenance off and empties every cache. `develop` also gets you out of a deployment that failed halfway.

This rehearses the Magento steps. The rehearsal isn't a copy of production: PHP keeps its development settings, so OPcache still notices changed files and Xdebug is still installed.

## Running the store's tests

```bash
bin/kapelos test                                   # unit and integration tests under app/code
bin/kapelos test unit                              # just the unit tests
bin/kapelos test integration app/code/Acme/Sales   # one module's integration tests
```

Unit tests run with Magento's own `dev/tests/unit/phpunit.xml.dist`, in the normal PHP container.

**Integration tests never touch the store's data.** The first run creates a database, a RabbitMQ virtual host and an OpenSearch index prefix just for tests, and writes `dev/tests/integration/etc/install-config-mysql.php` pointing at them. It holds local passwords, so keep it out of git.

Magento reinstalls itself into the test database at the start of every integration run, which takes a minute or two. To skip that once it's installed, copy `dev/tests/integration/phpunit.xml.dist` to `phpunit.xml` beside it and set `TESTS_CLEANUP` to `disabled`. Kapelos uses your `phpunit.xml` when there is one, for unit tests too.

The tests need PHPUnit, which is a development package. After `bin/kapelos deploy`, run `bin/kapelos develop` first.

## Auditing a site

```bash
bin/kapelos site audit          # the active site
bin/kapelos site audit acme     # or any site, running or not
```

Kapelos looks at the store itself, the things that go wherever the store goes:

| Section | What it checks | With |
|---|---|---|
| Dependencies | Every package in `composer.lock`, `package-lock.json` and the store's GitHub workflows, against OSV's advisories, Magento's own from NVD, and CISA's list of vulnerabilities being exploited now. A Mage-OS store is checked as the Magento release it's built on | [dep-intel](https://github.com/kingletas/dep-intel) |
| Credentials | The files git tracks, if the store is a repository of its own. Otherwise the folders in `AUDIT_PATHS`, which leaves out `vendor/` and the two files that hold credentials on purpose, `app/etc/env.php` and `auth.json` | [credential-guard](https://github.com/kingletas/credential-guard) |
| Security settings | Security modules switched off in `app/etc/config.php`, and unsafe values in the database, listed in `etc/audit/checks.tsv` | Kapelos |
| Files in `pub/` | Dumps, archives, logs, `phpinfo.php` and the like in `pub/`, and any script in `pub/media/`, the usual sign of a compromised store | Kapelos |
| Headers | `X-Frame-Options`, `X-Content-Type-Options` and the content security policy Magento sends | Kapelos |

Each line says `FAIL`, `WARN`, `pass` or `note`. The audit exits 1 if anything failed, so a script can stop on it.

**Expect the dependencies to fail on a fresh Mage-OS store.** Mage-OS 3.5 is checked as Magento 2.4.9, the release it's built on, and NVD's advisories match it. NVD's version ranges for Adobe products aren't always right, so read each advisory, and the confidence dep-intel gives the match, before acting on it.

If a feed the store needs couldn't be downloaded, such as Magento's own advisories, the audit fails and says which, rather than passing the packages it never checked.

The audit doesn't test the web server, because Kapelos's nginx isn't the one the store runs on in production. The settings and headers need the site running; it says so when they weren't checked.

The advisories download into `var/intel` the first time, about 35 MB, and refresh once a day, or sooner when a feed the store needs is missing. Every site shares them.

## Driving the store with bluetir and drexbot

Two browser test suites run against the active site, each in its own container, so you don't install Ruby, Node or a browser:

```bash
bin/kapelos sample-data            # the Luma catalogue both of them shop from
bin/kapelos bluetir probe          # does every selector resolve? places nothing
bin/kapelos bluetir                # adds to the cart, checks out and places an order
bin/kapelos bluetir order --runs 10
bin/kapelos drexbot                # drexbot's checks; the first run captures the catalogue
```

- **[bluetir](https://github.com/kingletas/bluetir)** drives Chromium through the Luma storefront. Its modes are `order` (the default), `pages`, `probe`, `persona`, `baseline` and `acceptance`, and anything after the mode goes to bluetir, such as `--runs 10` or `--seed 20260907`. Kapelos gives it `etc/bluetir/store.yml`, which points bluetir's own Luma order at the active site with no delay between pages. Screenshots land in `var/tools/<site>/bluetir/`.
- **[drexbot](https://github.com/kingletas/drexbot)** runs its regression, acceptance and performance checks with Playwright. Anything after `drexbot` goes to it; with nothing, it's `run --target magento`. Its ledgers, baselines and results live in `var/tools/<site>/drexbot/`, one set per site.

**Placing an order can't be taken back, so it needs the site's permission.** A site whose settings say `DISPOSABLE=yes` lets bluetir's `order` mode and drexbot's writing checks run; anything else refuses them, and bluetir says which modes still work. `demo` and `interactive` set it for the stores they make, and a store you bring stays `DISPOSABLE=no` until you change it.

**The tools use your machine's network**, so they open the store at exactly the address your browser uses, `localhost` included. That's also why a `.test` name has to be in `/etc/hosts` for them, as it does for you.

## Bundling JavaScript with manipulus

[manipulus](https://github.com/kingletas/manipulus) reads the store's code and works out which RequireJS modules each kind of page loads, then bundles them, so a page fetches a handful of files instead of a hundred or more. It reads the static files a production deploy writes, so it starts from a deployed store:

```bash
bin/kapelos deploy                  # production mode, static files written
bin/kapelos manipulus               # plan the bundles
bin/kapelos manipulus build -n      # what it would write
bin/kapelos manipulus build         # write them, and the module that loads them
bin/kapelos deploy                  # put them live
bin/kapelos manipulus explain Magento_Customer/js/customer-data
```

On the demo with sample data, the plan puts 167 modules in a bundle every page loads, and gives cart, category, checkout and product pages one each: five files, 3.4 MB in all.

**Kapelos looks after the part that's easy to get wrong.** The bundles live in `pub/static`, which a production deploy clears, so `kapelos deploy` writes them again after the static files every time, then refreshes the integrity hashes Magento checks on payment pages. Without that refresh, checkout can spin for ever. In developer mode the bundles module stays on and loads nothing, since the bundles only exist after a deploy.

The plan lives in `var/tools/<site>/manipulus/`, and `MANIPULUS_THEME` says which theme to bundle.

## Running the store's CI

```bash
bin/kapelos ci                     # every workflow in the store's .github/workflows, as a push would
bin/kapelos ci -j phpunit          # one job; anything after ci goes to act
bin/kapelos ci pull_request        # as a pull request would
```

This runs the store's own GitHub Actions workflows on your machine with [act](https://github.com/nektos/act), so you find out what CI will say before you push. Kapelos downloads act once into `var/bin/` and checks it against the checksum in `etc/act.tsv` before it ever runs it. A download that doesn't match is thrown away.

- **Each job gets a copy of the store, never the store itself**, and the copy follows the store's `.gitignore`. A workflow that runs `composer install` can't change your working tree. As on GitHub, a job sees the code only after its `actions/checkout` step.
- **The store has to be a git repository of its own**, as a real project is, because act reads the commit it's running.
- **Jobs run on the `catthehacker/ubuntu` images**, act's usual stand-ins for GitHub's runners, downloaded the first time. They're close to GitHub's but not identical, and a job that needs GitHub's secrets or services act can't provide will say so.

## HTTPS

Traefik, at the front of the stack, answers HTTPS on port 8443 straight away. Until you give it a certificate it uses its own self-signed one, so it works and the browser warns.

For a certificate your browser trusts, install [mkcert](https://github.com/FiloSottile/mkcert) and run:

```bash
bin/kapelos cert
```

That issues a certificate for `APP_HOST`, `localhost` and `127.0.0.1` into `etc/tls/`, and Traefik starts serving it without a restart. If the browser still warns, run `mkcert -install` once. Kapelos doesn't run that for you, because it changes which certificates your whole system trusts. After changing `APP_HOST`, run `bin/kapelos cert` again, since the certificate names the old host.

Then point the store at its HTTPS address, with `127.0.0.1 magento.test` in `/etc/hosts`:

```bash
MAGENTO_BASE_URL=https://magento.test:8443/
```

`bin/kapelos magento-install` uses that address. For a store that's already installed, set it in Magento too:

```bash
bin/kapelos config:set web/unsecure/base_url https://magento.test:8443/
bin/kapelos config:set web/secure/base_url https://magento.test:8443/
```

Want `https://magento.test/` with no port? Set `HTTPS_PORT=443`, if nothing else on your machine is using it.

## Xdebug

There's nothing to switch on. Kapelos runs two copies of PHP:

- **The normal one**, with Xdebug off, serves every ordinary request at full speed.
- **A debugging one**, with Xdebug on, gets only the requests that ask for it.

Traefik tells them apart before Varnish sees anything. A request carrying an Xdebug trigger, which is the cookie the Xdebug browser extension sets, or `?XDEBUG_SESSION=1` or `?XDEBUG_TRIGGER=1` on the URL, goes to the debugging copy. So a debug request never gets a cached page.

To debug a page:

1. Start listening in your IDE on port 9003.
2. Map the container's `/app` to your Magento folder in the IDE's path mappings. This is the one I forget most often.
3. Turn on the Xdebug browser extension, or add `?XDEBUG_TRIGGER=1` to the URL, and load the page.

Every response from the debugging copy carries an `X-Kapelos-Xdebug: on` header, so you can check where a request went in your browser's network tab.

To debug a Magento command, run it with `debug` in front:

```bash
bin/kapelos debug cache:flush
bin/kapelos debug indexer:reindex catalog_product_price
```

`XDEBUG_MODE` in `.env` sets what the debugging copy does, and it's `debug` unless you change it. For profiling, set `XDEBUG_MODE=debug,profile` and run `bin/kapelos up`. Then use the browser extension's Profile option, or `?XDEBUG_TRIGGER=1`. The debug cookie alone only starts debugging. Profiles land in `var/` in your Magento folder, as `cachegrind.out.*.gz` files.

## Full-page caching with Varnish

Out of the box Varnish passes every request straight through, so nothing is cached and nothing is stale while you work. To test caching, switch Magento to Varnish and have it write its own VCL:

```bash
bin/kapelos magento config:set system/full_page_cache/caching_application 2
bin/kapelos magento varnish:vcl:generate --export-version=7 --backend-host=web --backend-port=80 --access-list=0.0.0.0/0 --output-file=var/varnish.vcl
```

Set `VARNISH_VCL` in `.env` to that file on your machine, which is `var/varnish.vcl` inside your `MAGENTO_SRC`, then run `bin/kapelos up`.

To check it's working, load a page twice and look at the `X-Magento-Cache-Debug` header. It says `MISS` the first time and `HIT` after that. If it keeps saying `MISS`, wait two minutes: when the first response after a flush can't be cached, Magento's VCL stops trying for that long.

A few things worth knowing:

- **Purging works if Magento knows where Varnish is.** `bin/kapelos magento-install` sets that up. For a store installed some other way, run `bin/kapelos magento setup:config:set --http-cache-hosts=varnish:80`.
- **`--access-list=0.0.0.0/0` lets any container purge the cache.** That's fine inside this stack and wrong anywhere else.
- **On Mage-OS 3.5, the generator doesn't work.** Mage-OS swaps Magento's generator for the `Elgentos_VarnishExtended` module, which either stops with a `gracePeriod` type error or writes a file still full of placeholders like `{{ host }}`. Varnish refuses to load that file. Switch the module off to get Magento's own generator back: `bin/kapelos magento module:disable Elgentos_VarnishExtended`, then `bin/kapelos magento setup:upgrade`.
- **`bin/kapelos up` waits until Varnish can serve.** With Magento's VCL, that's once Magento's health check passes, which after a cold start can take up to a minute. If Varnish is still marked unhealthy from earlier, `up` says so, restarts it once and waits again.
- **Varnish reads the file when it starts.** After you regenerate it, run `bin/kapelos restart varnish`.

## Behind your own reverse proxy

If you already run [nginx-proxy](https://github.com/nginx-proxy/nginx-proxy) or anything else that routes on `VIRTUAL_HOST`, it can sit in front of Kapelos's Traefik instead of you using port 8443. Add the proxy layer in `.env`:

```bash
COMPOSE_FILE=compose.yaml:compose.proxy.yaml
PROXY_NETWORK=your-proxy-network
APP_HOST=magento.test
MAGENTO_BASE_URL=https://magento.test/
```

For more than one hostname, list them all: `PROXY_HOSTS=magento.test,second.test`. Your proxy serves each one the certificate named after it.

Your proxy handles HTTPS with its own certificate and tells Traefik the request was secure. Traefik believes that only from private network addresses, which is where a proxy on the same machine connects from. The Xdebug routing works the same through it.

The ports on `127.0.0.1` stay open either way, so a script can still reach the store directly.

## Additions only your machine needs

An extra mount, a module you're editing in another folder, a different memory limit: put them in `compose.local.yaml`, which is ignored by git, and add it to `COMPOSE_FILE`:

```bash
COMPOSE_FILE=compose.yaml:compose.local.yaml
```

```yaml
services:
  php:
    volumes: &module
      - /path/to/my-module:/app/app/code/Vendor/Module
  php-debug:
    volumes: *module
  cron:
    volumes: *module
```

A mount for PHP goes on all three PHP containers: `php`, `php-debug` for requests with Xdebug, and `cron`. [Examples](docs/examples.md) has more recipes like this one.

## Mac and Windows

**I've only run Kapelos on Linux.** I haven't run it on a Mac or on Windows, so treat both as expected to work rather than known to.

What I have checked: `bin/kapelos` is written for bash 3.2, which is what macOS ships, and `bin/kapelos check` runs its help, settings and error handling under bash 3.2 on every commit. The parts that drive Docker use the same bash, but I've only run them on Linux.

What to expect, and what to watch for:

- **macOS** needs Docker Desktop, OrbStack or Colima. Magento has tens of thousands of files, and a folder shared from macOS into Docker is much slower than on Linux. Turn on VirtioFS in Docker Desktop, and expect the first page loads in developer mode to be slow.
- **Windows** needs WSL 2 with Docker Desktop, and Kapelos run from inside WSL. Keep the code in the WSL file system, such as `~/stores`, not under `/mnt/c`, or every page will crawl. For trusted HTTPS, run `mkcert -install` on the Windows side as well, so Windows browsers trust the certificate.
- **`vm.max_map_count`** is a Linux setting. Docker Desktop sets it inside its own VM, so on a Mac there's usually nothing to do.

If you try either, I'd like to hear how it went.

## Checking your setup

```bash
bin/kapelos doctor
```

`doctor` checks this machine: Docker and Compose versions, memory, disk, and the tools Kapelos uses. Then the active site: whether its settings load, where its store is, whether the store's `.kapelos` files are trusted, whether its ports are free, whether its hostname resolves, whether the HTTPS certificate is about to expire, whether another stack uses the same store, and whether its service versions are ones its Magento release supports. It exits 1 if anything failed.

## Testing Kapelos itself

```bash
bin/kapelos self-test
```

`self-test` runs `check` and `check-image`, then builds a throwaway store in a temporary folder and checks that each feature works: the storefront, admin, HTTPS, the Xdebug routing, Magento commands, mail, `cache-reset`, `magento-install` refusing a database that exists, `import` and `connect`, and `deploy` and `develop`. It also installs the Kingletas modules and runs `site audit`, which has to find nothing failed outside the dependencies. Those depend on the advisories published that week, not on Kapelos. `self-test` leaves bluetir, drexbot, manipulus and `ci` out, because they need sample data and their own images, and would double its length. Then it removes the store and its data. It takes me five and a half minutes with the images already downloaded, and it refuses to start while a site is running, because it needs the ports.

## What Kapelos doesn't do

I left these out on purpose. Each one would make Kapelos bigger, and [Emporion](https://github.com/kingletas/emporion) already does them:

- **Several stores running at once.** Kapelos switches between projects instead. See [Several projects](#several-projects).
- **No image of your application.** Your code is mounted, never built into an image.
- **No Kubernetes.**

## Licence

[MIT](LICENSE).
