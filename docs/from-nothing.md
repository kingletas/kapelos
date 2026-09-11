# From nothing to a storefront

This takes you from a machine with Docker on it to a Magento store you can click around in, one step at a time, so you can see what each part does. You don't need Magento installed, and you don't need an Adobe account.

> [!TIP]
> In a hurry? `bin/kapelos demo` does all of this in one command and asks nothing. This guide is for seeing how Kapelos works.

It took me about ten minutes, most of it downloads. Every time in this guide is from my machine, so yours will differ.

## Contents

- [What you need](#what-you-need)
- [Step 1: get Kapelos and its settings](#step-1-get-kapelos-and-its-settings)
- [Step 2: make a folder for the store](#step-2-make-a-folder-for-the-store)
- [Step 3: download Magento into it](#step-3-download-magento-into-it)
- [Step 4: start the stack](#step-4-start-the-stack)
- [Step 5: install the store](#step-5-install-the-store)
- [Step 6: open it](#step-6-open-it)
- [When something goes wrong](#when-something-goes-wrong)
- [Where to go next](#where-to-go-next)

## What you need

- **Docker with Compose v2.** Check with `docker compose version`.
- **`git`.** `make` is optional.
- **About 6 GB of free memory.**
- **On Linux, `vm.max_map_count` of at least 262144.** OpenSearch won't start below that. Check it with `sysctl vm.max_map_count`, and raise it until the next reboot with:

```bash
sudo sysctl -w vm.max_map_count=262144
```

## Step 1: get Kapelos and its settings

```bash
git clone https://github.com/kingletas/kapelos && cd kapelos
bin/kapelos env
```

`bin/kapelos env` copies `.env.example` to `.env` and fills every password with a random one. You'll see:

```text
Wrote .env. Set MAGENTO_SRC in it to your Magento tree, then run: kapelos up
```

Every `bin/kapelos` command in this guide also works through make, as `make env`, `make up` and so on.

## Step 2: make a folder for the store

Magento lives outside Kapelos, in a folder of its own. Make an empty one:

```bash
mkdir -p ~/magento
```

Open `.env` and point `MAGENTO_SRC` at it. Use the full path:

```bash
MAGENTO_SRC=/home/you/magento
```

## Step 3: download Magento into it

This uses Composer inside Kapelos's PHP container, so you don't need PHP on your machine. The first time, Docker builds that container, which takes a few minutes.

[Mage-OS](https://mage-os.org) is a community distribution of Magento that anyone can download:

```bash
docker compose run --rm --no-deps php composer create-project --repository-url=https://repo.mage-os.org/ mage-os/project-community-edition .
```

The `.` at the end matters. It means "into `MAGENTO_SRC`", and the folder has to be empty.

If you'd rather have Magento Open Source, you need access keys from your Magento Marketplace account. Give them to Composer once, then create the project from Adobe's repository instead:

```bash
docker compose run --rm --no-deps php composer config -g http-basic.repo.magento.com <public-key> <private-key>
docker compose run --rm --no-deps php composer create-project --repository-url=https://repo.magento.com/ magento/project-community-edition .
```

When it's done, the last lines look like this:

```text
Generating autoload files
156 packages you are using are looking for funding.
No security vulnerability advisories found.
```

## Step 4: start the stack

```bash
bin/kapelos up
```

`up` starts twelve containers and waits until each one is healthy. On a warm machine that takes about half a minute:

```text
 Container kapelos-db-1  Healthy
 Container kapelos-valkey-session-1  Healthy
 Container kapelos-rabbitmq-1  Healthy
 Container kapelos-opensearch-1  Healthy
 Container kapelos-varnish-1  Healthy
```

If `up` stops early, see [When something goes wrong](#when-something-goes-wrong).

## Step 5: install the store

```bash
bin/kapelos magento-install
```

This creates the database tables, connects Magento to the search engine, queue and caches, and makes an admin account. It takes about a minute, and ends with:

```text
[SUCCESS]: Magento installation complete.
[SUCCESS]: Magento Admin URI: /admin
Enabled developer mode.

Installed. Storefront: http://magento.test:8080/
Admin: http://magento.test:8080/admin as admin, password in .env
```

The admin password is `MAGENTO_ADMIN_PASSWORD` in `.env`.

## Step 6: open it

The store answers at `magento.test`, which your machine doesn't know about yet. Add one line to `/etc/hosts`:

```text
127.0.0.1 magento.test
```

Now open <http://magento.test:8080/>. You'll see an empty Luma store with a "Home Page" heading. The first page takes a few seconds, because Magento builds its styles and scripts the first time each one is asked for.

The same store answers over HTTPS at <https://magento.test:8443/>, with a browser warning until you run `bin/kapelos cert`. The README's HTTPS section has the rest.

The admin is at <http://magento.test:8080/admin>. The first time you log in, Magento asks you to set up two-factor authentication and emails you a link. Every email the store sends lands in Mailpit, at <http://127.0.0.1:8025>.

## When something goes wrong

**`set MAGENTO_SRC in .env to the Magento tree you want to run`.** `MAGENTO_SRC` is empty. Set it and run the command again.

**`bind source path does not exist`.** `MAGENTO_SRC`, or another path in `.env`, points at a folder or file that isn't there. Check the spelling, and use a full path.

**`set DB_PASSWORD in .env, or run kapelos env`.** Your `.env` wasn't made by `bin/kapelos env`, so it has no passwords. Move it aside and run `bin/kapelos env` again.

**OpenSearch never becomes healthy.** Every time I've hit this, it was `vm.max_map_count`. See [What you need](#what-you-need). `bin/kapelos logs opensearch` will say so.

**`this tree already has app/etc/env.php`.** The store is already installed, so `bin/kapelos magento-install` won't install over it. To start again from an empty database, run `docker compose down -v`, which **deletes** the database and search index, then remove `app/etc/env.php` and install again.

**A page says "Backend fetch failed".** Varnish can't reach nginx. `bin/kapelos ps` shows which container isn't running, and `bin/kapelos logs` shows why.

## Where to go next

- [README](../README.md): everyday commands, Xdebug, Varnish caching and HTTPS behind a reverse proxy
- [SECURITY.md](../SECURITY.md): what the local defaults mean
- [CONTRIBUTING.md](../CONTRIBUTING.md)
