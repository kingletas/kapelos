# What Kapelos ships here

`share/` holds things Kapelos ships for you to use but doesn't run itself, the way `/usr/share` does on a Linux system.

## `commands/`

Working examples of [your own commands](../docs/examples.md#your-own-commands). Kapelos doesn't run them from here. `kapelos commands` puts them where it does:

```bash
kapelos commands             # what there is, and where each one is installed
kapelos commands add         # all of them, into the store you're working on
kapelos commands add orders  # just that one
kapelos commands add --user  # into ~/.config/kapelos/commands, so they follow you into every store
kapelos commands remove      # take them out again
```

**It brings each command's `lib/` files with it** and takes them away again when nothing left names them. Every command reads its PHP and SQL from a `lib/` folder next to itself, which is where Kapelos expects a command's helpers to live: `lib/` is covered by trust like the commands, and `kapelos` doesn't mistake anything in it for a command of its own.

`orders`, `profile` and `indexers` copy their PHP into the store's `var/kapelos/` and run it from there, because that is the one folder both your machine and the PHP container can see. It is Magento's own scratch folder, so nothing you keep is in it.

**A file you've changed is left alone.** `add` won't write over it and `remove` won't delete it until you say `-f`. They are examples meant to be edited, so the copy in a store is worth more than the copy Kapelos ships.

A command in a store's `.kapelos/commands/` runs only after `kapelos trust`. **`kapelos commands add` trusts them for you when there's nothing else in `.kapelos` you haven't read.** A compose file, or somebody else's command sitting in the same folder, means it won't, and it says so. One in `~/.config/kapelos/commands/` needs no trust, because you put it there yourself.

| Command | What it does |
|---|---|
| `orders` | Places real orders through the quote and `QuoteManagement::submit()`, a batch at a time |
| `seed-grid` | Fills `sales_order_grid` with synthetic rows so the admin grid can be timed at production volume, and takes them out again |
| `profile` | Times the admin order grid, the dashboard or the product form, with the plan the database chose for each query |
| `mail` | Lists what the store has emailed, and prints one message |
| `indexers` | Every indexer's state, and how far behind its changelog is |
| `big-tables` | The largest tables in the database, and which ones are only logs |
| `queue-depth` | How many messages are sitting in each RabbitMQ queue |

`orders` and `seed-grid` write to the store. Both refuse to run unless the site is `DISPOSABLE=yes`, which `kapelos demo` and `kapelos interactive` set and a store you bring does not.

## Writing your own

Start from any of these, once `kapelos commands add` has put one in front of you. The shape is the same every time: a comment on the line under the shebang, which `kapelos help` lists, then bash that calls `"$KAPELOS"` for anything it needs from the stack. [The examples page](../docs/examples.md#your-own-commands) has the rest.
