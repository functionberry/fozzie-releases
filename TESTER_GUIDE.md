# Fozzie private beta: tester guide

Thanks for testing Fozzie. This guide covers installing it, keeping it up
to date, backups, running agents, and removing it again. Everything runs on your own
machine in Docker, and nothing is reachable from outside it: every port
listens on `localhost` only.

## What you need

- **Docker.** Docker Desktop on macOS or Windows, or Docker Engine on
  Linux. It needs Docker Compose **v2.20.0 or newer**: check with
  `docker compose version`.
- **A GitHub account.** Fozzie's images are in GitHub's container
  registry, and access is per account.
- **About 2 GB of free disk** for the images, plus whatever your data
  grows to.

## Getting access

1. Send Mark your GitHub username.
2. GitHub then emails you an invite for each of the five Fozzie packages
   (`fozzie-dist-core-api`, `fozzie-dist-dashboard`, `fozzie-dist-updater`,
   `fozzie-dist-agent` and `fozzie-dist-orchestrator`). Accept all five. Until you do, the installer
   can't download Fozzie.

## Creating a GitHub token

The installer needs a GitHub **classic** personal access token to download
the images. Create one here:

<https://github.com/settings/tokens/new?scopes=read:packages&description=Fozzie%20beta>

- Tick **only** `read:packages`. Fozzie needs nothing else, so don't give
  it anything else.
- Pick whatever expiry you're happy with. When it expires, create a new
  one and re-run the installer.
- Copy the token when GitHub shows it: it's only shown once.

## Installing

In a terminal, run:

```sh
curl -fsSL https://functionberry.github.io/fozzie-releases/install.sh | bash
```

It checks Docker, then asks for your GitHub username and the token (the
token isn't shown as you type). It downloads Fozzie, starts it, and opens
your browser on a "create your account" page. The first install can take
a few minutes.

If you've already run `docker login ghcr.io` yourself, it may not need to
ask. It then offers to save your username and token anyway: in-app
updates will need them (see [Updating](#updating)). You can skip that and
add them later by re-running the installer.

To run it without any questions, set the credentials in the environment
and pass `--yes`:

```sh
curl -fsSL https://functionberry.github.io/fozzie-releases/install.sh | GHCR_USERNAME=you GHCR_TOKEN=ghp_... bash -s -- --yes
```

## More than one instance, and other ports

By default Fozzie uses ports 4000 and 5173, at <http://localhost:5173>. To
run a second, separate instance, give it a name and two free ports the
first time:

```sh
curl -fsSL https://functionberry.github.io/fozzie-releases/install.sh | bash -s -- --name second --core-port 4010 --dashboard-port 5183
```

Later runs for that instance just need `--name second`: its ports are
remembered. Run with `--help` to see every option.

## Where things live

Fozzie installs into `~/fozzie` (or `~/fozzie-<name>` for a named
instance). That directory holds two files:

- `docker-compose.yml`, which describes the containers. The installer
  replaces it on every run.
- `.env`, which holds your instance's settings and **secrets**: its
  database password, its encryption key and **your GitHub token**, which
  is kept there so that in-app updates can download new versions. It's
  readable only by you (`chmod 600`). Don't share it or commit it
  anywhere. The installer keeps any line you add to it, for example SMTP
  settings.

Your data itself (the database, git repositories, attachments and
backups) lives in Docker volumes, not in that directory. It can only be
opened with this `.env`: its database password and encryption key are
the ones the data was created with, and your backups are encrypted with
that key. Keep a private copy of `.env` somewhere safe.

## Updating

When a new release is out, admins see an "Update available" banner at
the top of Fozzie. Click **Update** there, or in Settings → Updates, and
confirm. Fozzie then:

1. takes a backup;
2. downloads the new version;
3. restarts on it, so it's unavailable for a minute or two;
4. checks that the new version started.

A progress window shows each step. You can hide it and keep using any page
you already have open. It comes back if you reload. When it says "Updated",
click **Reload** to load the new version. If the new version doesn't
start, Fozzie automatically goes back to the version you had, and your data
is safe.

You can always update by re-running the same install command instead (with
`--name` if you used one). It keeps your data and settings, takes a backup
first, and then switches to the latest release. Do this if Fozzie says your
version is too old to update in place, or that the updater is out of date.

## Backups

Fozzie backs itself up daily and keeps the newest 14 backups, in the
`fozzie_backups_local` Docker volume. The installer also takes one before
every update.

Run these from `~/fozzie` (or `~/fozzie-<name>`, with `-p fozzie-<name>`):

```sh
cd ~/fozzie
# List the backups
docker compose -p fozzie-local --env-file .env run --rm backup node dist/backupCli.js list
# Take one now
docker compose -p fozzie-local --env-file .env run --rm backup node dist/backupCli.js run
```

If you need to restore one, ask Mark: restoring replaces your current
data, so it's worth doing together.

## Locked out?

If you've forgotten your password and nobody else can reset it for you,
you can get a reset link from a terminal on this computer. Run this from
`~/fozzie` (or `~/fozzie-<name>`, with `-p fozzie-<name>`), using the
email address you sign in with:

```sh
cd ~/fozzie
docker compose -p fozzie-local --env-file .env exec core-api node dist/adminCli.js reset-password you@example.com
```

It prints a link that works once, for an hour. Open it in your browser
and choose a new password. That signs the account out everywhere else and
revokes its API tokens.

Fozzie must be running: `exec` needs the `core-api` container up. If it
isn't, start Fozzie first (see [Stopping and starting](#stopping-and-starting)).

Anyone with a terminal on this computer can do this, so it works even when
you're the only admin.

## Stopping and starting

```sh
cd ~/fozzie
docker compose -p fozzie-local --env-file .env stop    # stop
docker compose -p fozzie-local --env-file .env up -d   # start again
```

Fozzie also starts by itself when Docker does, until you stop it.

## Uninstalling

There are two ways to uninstall, and they're very different. The
installer can ask you which one you want and do it for you (add
`--name` if you used one):

```sh
curl -fsSL https://functionberry.github.io/fozzie-releases/install.sh | bash -s -- --uninstall
```

Or do it by hand:

**(a) Remove Fozzie, but keep your data to reinstall later.**

```sh
cd ~/fozzie
docker compose -p fozzie-local --env-file .env down
```

This removes the containers and **keeps your data** in its Docker
volumes. **Keep `~/fozzie/.env` too** (or a private copy of it): it holds
the database password and encryption key that data needs. Re-running the
installer with that `.env` in place brings it all back. Without it, the
data can't be opened (see
[Troubleshooting](#troubleshooting)).

**(b) Remove everything.**

> [!WARNING]
> This deletes **your database, repositories, attachments and every
> backup, permanently**. There is no undo.

```sh
cd ~/fozzie
docker compose -p fozzie-local --env-file .env down -v
cd ~ && rm -rf ~/fozzie
docker logout ghcr.io
```

Then revoke the token at <https://github.com/settings/tokens>.

Only delete the `~/fozzie` directory after `down -v`: deleting it after a
plain `down` leaves your data behind with nothing that can open it.

## Using a local model (Ollama)

You can use a model server running on your own computer, such as Ollama,
as an AI provider:

1. Start Ollama so Docker can reach it. By default it only accepts
   connections from your computer itself, which shuts Fozzie out:

   ```sh
   OLLAMA_HOST=0.0.0.0 ollama serve
   ```

   On Linux, if Ollama runs as a systemd service, run
   `sudo systemctl edit ollama`, add these lines, save, then run
   `sudo systemctl restart ollama`:

   ```ini
   [Service]
   Environment="OLLAMA_HOST=0.0.0.0"
   ```

2. In Fozzie, go to Settings → AI providers and click **Add resource**.
   Pick the **OpenAI-compatible** provider type, and set the base URL to
   `http://host.docker.internal:11434/v1`. Don't use `localhost`: Fozzie's
   server runs in its own container, so to it `localhost` means that
   container, not your computer.

3. `host.docker.internal` works on Mac, Windows and Linux (Fozzie's compose
   file sets it up on Linux). If listing the models fails, the error says
   what to fix.

## Agents

Agents are AI workers that pick up work you assign to them. They run in
their own containers, started by the **agent service**, which the
installer turns on by default. It uses an AI provider you supply.

To set one up:

1. In Fozzie, go to **Agents** and click **Set up an agent**.
2. Give it a name, pick an AI provider and model (and a budget, if the
   provider charges per use), and choose its repository.
3. The last step offers a first task, set up as a coding task and
   assigned to the agent. Create it, then watch the agent on the
   **Agents** page: it shows **Running** while it works on the task, and
   **Idle** when it's waiting for more.

To turn the agent service off, re-run the installer with `--no-agents`
(and `--name` if you used one). Later runs remember that. To turn it back
on, use `--with-agents`:

```sh
curl -fsSL https://functionberry.github.io/fozzie-releases/install.sh | bash -s -- --no-agents
curl -fsSL https://functionberry.github.io/fozzie-releases/install.sh | bash -s -- --with-agents
```

If you installed Fozzie before agents shipped, re-run the installer once
to add the agent service: in-app updates don't add it. Until then, the
Agents page says "Agent service not set up on this instance" and shows
the command to run.

## Feedback

Email Mark at <TODO: Mark to fill in>. Screenshots, the version (shown in
Settings) and what you were doing all help.

## Troubleshooting

**Forgot your password?** See [Locked out?](#locked-out).

**"Docker isn't running."** Start Docker Desktop (or the Docker service on
Linux), wait until it says it's running, then run the installer again.

**"Docker Compose … is too old."** Update Docker Desktop, or the Compose
plugin on Linux, to one with Compose v2.20.0 or newer, then try again.

**`unauthorized`, or "GitHub didn't accept that username and token".** The
username or token is wrong, or the token has expired or been revoked.
Create a new token (see [Creating a GitHub token](#creating-a-github-token))
and run the installer again.

**`denied`, or "your GitHub account hasn't been given access".** Your
account doesn't have access to the packages yet. Check you've accepted
every invite, or ask Mark to add your GitHub username.

**"That token is missing the read:packages scope."** The token was created
without `read:packages`. Create a new one with only that ticked.

**A port is already in use.** Something else on your machine is using
4000 or 5173 (or the ports you picked). Re-run the installer with other
ports, for example `--core-port 4001 --dashboard-port 5174`.

**"… already has data …, but … has no database password for it" (or "a
different one").** An earlier install's data is still in Docker, but its
`.env` was deleted or replaced, for example by removing `~/fozzie` after
a plain `down`. The installer won't make a new password for that data:
it would never open. Either:

- **keep the data**: copy the old `.env` back to `~/fozzie/.env` and run
  the installer again, or run it with `--import-env /path/to/old/.env`.
  Entering just the old password isn't enough: `.env` also holds the
  encryption key your data and backups need. Or
- **start fresh**: run the installer again in a terminal and pick
  "Start fresh". It lists what it will delete and asks you to type the
  instance's name (e.g. `fozzie-local`) first. This deletes all of that
  instance's data and backups, permanently.

**"The backup failed because the database refused its password."** The
same cause as the previous entry: this `.env` isn't the one the data was
created with. Do the same.

**"core-api didn't become healthy within 3 minutes."** The installer
prints the likely cause when core-api's logs show one: for example, that
the database refused its password (see the entries above). Otherwise,
look at its logs for the reason:

```sh
cd ~/fozzie
docker compose -p fozzie-local --env-file .env logs core-api
```

The last lines usually say what went wrong. Send them to Mark if it isn't
obvious.

**"Couldn't list models" for a model on your computer.** See
[Using a local model (Ollama)](#using-a-local-model-ollama): use
`host.docker.internal`, not `localhost`, and start Ollama with
`OLLAMA_HOST=0.0.0.0`.

**"The updater didn't respond."** The `updater` container, which carries
out one-click updates, isn't running. Check it:

```sh
cd ~/fozzie
docker compose -p fozzie-local --env-file .env ps updater
```

If it isn't listed as running, re-run the installer: that starts it again,
and also updates Fozzie.

**"Agent service not set up on this instance."** This install doesn't
run the agent service yet: it was probably installed before agents
shipped. Re-run the installer (see [Agents](#agents)).

**An agent doesn't start, or the Agents page says the agent service isn't
running.** Check the orchestrator's logs, which show what the agent
service is doing:

```sh
cd ~/fozzie
docker compose -p fozzie-local --env-file .env logs orchestrator
```

For a named instance, use `~/fozzie-<name>` and `-p fozzie-<name>`. If
you turned agents off with `--no-agents`, turn them back on with
`--with-agents` (see [Agents](#agents)).

**"The orchestrator's heartbeat to core-api is failing (HTTP 401)" (or
404).** The agent service and Fozzie don't agree on the secret it reports
in with. Re-run the installer: it sets the secret up again for both.

**"Fozzie couldn't go back on its own."** An update failed, and so did the
automatic rollback. The progress window shows the steps to fix it by hand,
in a terminal. Follow them, then check Fozzie starts. If it still doesn't,
your backups are safe in their own volume (see [Backups](#backups)):
contact Mark before restoring one.
