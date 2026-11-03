# Fozzie private beta: tester guide

Thanks for testing Fozzie. This guide covers installing it, keeping it up
to date, backups, and removing it again. Everything runs on your own
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
2. GitHub then emails you an invite for each of the three Fozzie packages
   (`fozzie-dist-core-api`, `fozzie-dist-dashboard` and
   `fozzie-dist-updater`). Accept all three. Until you do, the installer
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
backups) lives in Docker volumes, not in that directory.

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

## Stopping and starting

```sh
cd ~/fozzie
docker compose -p fozzie-local --env-file .env stop    # stop
docker compose -p fozzie-local --env-file .env up -d   # start again
```

Fozzie also starts by itself when Docker does, until you stop it.

## Uninstalling

```sh
cd ~/fozzie
docker compose -p fozzie-local --env-file .env down
```

This removes the containers and **keeps your data**: re-running the
installer brings it all back.

> [!WARNING]
> `docker compose -p fozzie-local --env-file .env down -v` also deletes
> the volumes: **your database, repositories, attachments and every
> backup, permanently**. There is no undo. Only run it if you want
> everything gone.

To remove the rest:

- delete the directory: `rm -rf ~/fozzie`;
- log Docker out of GitHub's registry: `docker logout ghcr.io`;
- revoke the token at <https://github.com/settings/tokens>.

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

## Feedback

Email Mark at <TODO: Mark to fill in>. Screenshots, the version (shown in
Settings) and what you were doing all help.

## Troubleshooting

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

**"core-api didn't become healthy within 3 minutes."** Look at its logs
for the reason:

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

**"Fozzie couldn't go back on its own."** An update failed, and so did the
automatic rollback. The progress window shows the steps to fix it by hand,
in a terminal. Follow them, then check Fozzie starts. If it still doesn't,
your backups are safe in their own volume (see [Backups](#backups)):
contact Mark before restoring one.
