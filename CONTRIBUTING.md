# Contributing

Thanks for looking.

## The gate

```bash
bin/kapelos check
```

That's everything a commit has to pass. `make check` runs the same thing. `check` makes sure both compose layouts are valid, that a missing `MAGENTO_SRC` is refused, and that the scripts and YAML are clean. It needs Docker, `shellcheck` and `yamllint`.

If you changed the PHP image, run this too:

```bash
bin/kapelos check-image
```

`check-image` builds the image both ways, with and without SourceGuardian, and fails if any extension Magento needs is missing.

Before a change that touches how the stack runs, run the whole thing:

```bash
bin/kapelos self-test
```

`self-test` builds a throwaway store, checks every feature against it, and removes it. It takes me about five minutes once the images are downloaded, and needs no site running.

## What a change should look like

- **Keep it small.** I keep Kapelos simple enough to read in one sitting. A feature that needs a second store, a cluster or a build of your application belongs in a bigger tool.
- One concern per pull request, with the reasoning in the description.
- `bin/kapelos check` green, `bin/kapelos check-image` green if the image changed, and `bin/kapelos self-test` green if the stack changed.
- `bin/kapelos` runs under bash 3.2, for macOS. `check` tests that, so no `mapfile`, associative arrays or `${var,,}`.
- A new command goes in `bin/kapelos`, with a make target of the same name that calls it.
- An entry in `CHANGELOG.md` saying what changed for someone using Kapelos, not what the diff did.
- Comments say what the code does or what it guards against, in a sentence or two. History belongs in the commit message and the changelog.

## Security

Don't open a public issue for a vulnerability. [SECURITY.md](SECURITY.md) has the reporting route.
