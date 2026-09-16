# A Magento 2 development stack for a Magento tree you already have. Run `make` for the list.
# Every target calls bin/kapelos, which does the same without make.

SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

KAPELOS := ./bin/kapelos
ARGS ?=
PREFIX ?= $(HOME)/bin

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

# --- installing ---

.PHONY: install
install: ## Put a kapelos command on your PATH that runs this folder (PREFIX= to change, default ~/bin)
	@scripts/install "$(PREFIX)"

.PHONY: uninstall
uninstall: ## Remove that command; every site stays in this folder
	@scripts/uninstall "$(PREFIX)"

# --- getting a store ---

.PHONY: demo
demo: ## Download and install a demo store, with no questions
	@$(KAPELOS) demo

.PHONY: interactive
interactive: ## Ask a few questions, then set a store up without asking again
	@$(KAPELOS) interactive

.PHONY: sites
sites: ## List the sites and which one is active
	@$(KAPELOS) sites

.PHONY: use
use: ## Switch to a site, stopping whichever one is running — make use ARGS="acme"
	@$(KAPELOS) use $(ARGS)

.PHONY: import
import: ## Load a database dump into an empty database — make import ARGS="store.sql.gz"
	@$(KAPELOS) import $(ARGS)

.PHONY: connect
connect: ## Point an existing store's settings at Kapelos, after import
	@$(KAPELOS) connect

.PHONY: adopt
adopt: ## Run a store you already have, as it is: make adopt ARGS="~/store --datadir ~/store-db"
	@$(KAPELOS) adopt $(ARGS)

# --- setup ---

.PHONY: env
env: ## Write settings with generated passwords — make env, or make env ARGS="acme"
	@$(KAPELOS) env $(ARGS)

.PHONY: build
build: ## Build the PHP image
	@$(KAPELOS) build

.PHONY: cert
cert: ## Issue a trusted certificate for APP_HOST with mkcert, and serve it
	@$(KAPELOS) cert

# --- the stack ---

.PHONY: up
up: ## Start everything, or apply a change to .env, and wait until it is healthy
	@$(KAPELOS) up

.PHONY: down
down: ## Stop everything, keeping the database and search index
	@$(KAPELOS) down

.PHONY: restart
restart: ## Restart services after editing etc/ — make restart ARGS="php"
	@$(KAPELOS) restart $(ARGS)

.PHONY: ps
ps: ## What is running, and whether it is healthy
	@$(KAPELOS) ps

.PHONY: info
info: ## Every address, port and login: store, admin, mail, database, Valkey, OpenSearch, RabbitMQ
	@$(KAPELOS) info

.PHONY: valkey
valkey: ## valkey-cli on the cache or session instance — make valkey ARGS="session"
	@$(KAPELOS) valkey $(ARGS)

.PHONY: logs
logs: ## Follow the logs — make logs ARGS="php"
	@$(KAPELOS) logs $(ARGS)

# --- working in the store ---

.PHONY: magento-install
magento-install: ## Install Magento into the running stack
	@$(KAPELOS) magento-install

.PHONY: shell
shell: ## A shell in the PHP container, at the Magento root
	@$(KAPELOS) shell

.PHONY: magento
magento: ## Run bin/magento — make magento ARGS="cache:flush"
	@$(KAPELOS) magento $(ARGS)

.PHONY: debug
debug: ## Run a Magento command with Xdebug — make debug ARGS="cache:flush"
	@$(KAPELOS) debug $(ARGS)

.PHONY: composer
composer: ## Run composer — make composer ARGS="install"
	@$(KAPELOS) composer $(ARGS)

.PHONY: db
db: ## A MariaDB prompt on the store's database
	@$(KAPELOS) db

.PHONY: cache-reset
cache-reset: ## Empty every cache: Magento, Valkey and Varnish. Sessions are kept
	@$(KAPELOS) cache-reset

.PHONY: audit
audit: ## Audit the active site — make audit, or make audit ARGS="acme"
	@$(KAPELOS) site audit $(ARGS)

.PHONY: sample-data
sample-data: ## Add Magento's sample products
	@$(KAPELOS) sample-data

.PHONY: bluetir
bluetir: ## Drive the store with bluetir — make bluetir ARGS="probe"
	@$(KAPELOS) bluetir $(ARGS)

.PHONY: drexbot
drexbot: ## Run drexbot against the store — make drexbot ARGS="probe --target magento"
	@$(KAPELOS) drexbot $(ARGS)

.PHONY: manipulus
manipulus: ## Plan or build JavaScript bundles — make manipulus ARGS="build -n"
	@$(KAPELOS) manipulus $(ARGS)

.PHONY: ci
ci: ## Run the store's GitHub Actions workflows with act — make ci ARGS="-j phpunit"
	@$(KAPELOS) ci $(ARGS)

.PHONY: modules
modules: ## The Kingletas modules — make modules, or make modules ARGS="add process-guard"
	@$(KAPELOS) modules $(ARGS)

.PHONY: repositories
repositories: ## The Composer repositories Kapelos knows: make repositories, or make repositories ARGS="packages kingletas"
	@$(KAPELOS) repositories $(ARGS)

.PHONY: commands
commands: ## The commands Kapelos ships for you — make commands, or make commands ARGS="add orders"
	@$(KAPELOS) commands $(ARGS)

.PHONY: snapshot
snapshot: ## Save or restore the database, search and queue — make snapshot ARGS="save clean"
	@$(KAPELOS) snapshot $(ARGS)

.PHONY: cron
cron: ## Magento's scheduled jobs — make cron ARGS="on"
	@$(KAPELOS) cron $(ARGS)

.PHONY: npm
npm: ## npm at the store's root — make npm ARGS="install"
	@$(KAPELOS) npm $(ARGS)

.PHONY: grunt
grunt: ## Magento's grunt, with LiveReload — make grunt ARGS="watch"
	@$(KAPELOS) grunt $(ARGS)

.PHONY: stores
stores: ## Which store each hostname runs — make stores ARGS="apply"
	@$(KAPELOS) stores $(ARGS)

.PHONY: queues
queues: ## Declare the store's queues in RabbitMQ and check each is there
	@$(KAPELOS) queues

.PHONY: trust
trust: ## Allow the store's .kapelos compose file and commands to run
	@$(KAPELOS) trust $(ARGS)

.PHONY: doctor
doctor: ## Check this machine and this site
	@$(KAPELOS) doctor

.PHONY: deploy
deploy: ## Rehearse a production deployment on this tree
	@$(KAPELOS) deploy

.PHONY: develop
develop: ## Go back to developer mode after a deploy
	@$(KAPELOS) develop

.PHONY: test
test: ## Run the store's PHPUnit tests — make test ARGS="unit app/code/Vendor"
	@$(KAPELOS) test $(ARGS)

# --- the gate ---

.PHONY: check
check: ## Everything a commit has to pass
	@$(KAPELOS) check
	@scripts/check-install

.PHONY: check-image
check-image: ## Build the PHP image and check every extension Magento needs is in it
	@$(KAPELOS) check-image

.PHONY: self-test
self-test: ## Build a throwaway store and prove every feature works, then remove it
	@$(KAPELOS) self-test
