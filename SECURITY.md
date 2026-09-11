# Security policy

## What this is, and what it isn't

Kapelos is a development stack for one machine. It isn't hardened, and it isn't meant to serve real customers. A few of its defaults only make sense because of that, so here they are:

- **Every port binds to `127.0.0.1`.** Setting `BIND_ADDRESS=0.0.0.0` puts the database, the store, OpenSearch, RabbitMQ and the mail sink on your network, where anyone who can reach the machine can reach them.
- **OpenSearch runs with its security plugin off.** It has no password, so any program on your machine can read and change the search index through `127.0.0.1:9200`.
- **`bin/kapelos info` prints the passwords**, so you can paste them into a database tool. They land in your terminal's scrollback, and in a log if you run it somewhere that keeps one.
- **`bin/kapelos env` writes the passwords into `.env`**, or into a site's file in `etc/sites/`, readable only by you. They protect a local store, not anything real. Don't reuse them.
- **Anyone who can reach the store can start a debugging session.** A request with an Xdebug trigger goes to the debugging PHP, which connects to port 9003 on your machine. That's only your IDE while everything binds to `127.0.0.1`.
- **Traefik believes `X-Forwarded-Proto` from private addresses**, so a reverse proxy on the same machine can say a request was HTTPS. Anything on a private network that can reach the store can say the same.
- **Traefik reads its routes from files and has no access to Docker.** Nothing in the stack mounts the Docker socket.
- **The audit tools come from GitHub at a pinned commit.** `opt/audit/Dockerfile` names the commit of dep-intel and credential-guard it builds, since I don't publish releases of either yet.
- **act is checked against Kapelos's own record of its checksum**, in `etc/act.tsv`, not against the one published beside the download, so a release changed after the fact is refused.
- **SourceGuardian is downloaded without a checksum**, because the vendor doesn't publish one. It's off unless you set `INSTALL_SOURCEGUARDIAN=true`.
- **An adopted store keeps its own credentials.** `kapelos adopt` repoints the store's servers, search and mail, and leaves every other setting as it was, including keys for payment providers and feeds to outside servers. Kapelos never runs cron, so scheduled exports don't run, but anything you trigger by hand uses those keys. Its database copy holds whatever customers the original held. `adopt` marks the site `DISPOSABLE=no`, so the browser tools won't place orders in it.
- **`var/sites/<site>/env.php` is readable only by you**, since it holds the store's encryption key.
- **A store's `.kapelos/compose.yaml` and `.kapelos/commands` run with your permissions.** A compose file can mount any folder and run any image, and a command is a program. Kapelos runs them only after `kapelos trust`, keyed to their exact contents, so a change pulled with the code stops them until you trust them again. Read them before you do. `.kapelos/settings.env` can only set facts about the store, and a line setting anything else is refused.
- **Dumps and snapshots hold whatever customers the database holds.** Dumps go to `var/dumps`, readable only by you; snapshots are Docker volumes on your machine.
- **Cron on a store you brought runs its real jobs**, with its real credentials: feeds, exports and emails to outside servers. It's off until you turn it on, and on a site that isn't `DISPOSABLE=yes` it asks first.

## Supported versions

I support the `main` branch, and fix the current minor version in tagged releases.

## Reporting a vulnerability

**Don't open a public issue.**

Report it privately through GitHub's [private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability) on this repository. That opens a draft advisory only I can see. Or email **code@kingletas.com**.

Tell me what it does wrong, how to reach it, and what an attacker gets.

I'll reply to say I have it, then tell you whether it's real and how serious it is. Anything I confirm gets a fix, and a check that stops it coming back.
