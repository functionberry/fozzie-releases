# Fozria private beta: tester guide

Thanks for testing Fozria. This guide covers installing it, keeping it up
to date, backups, running agents, and removing it again. Everything runs on your own
machine in Docker. By default nothing is reachable from outside it: every
port listens on `localhost` only. You can opt in to opening the dashboard
to your network; see
[Using Fozria from another device](#using-fozria-from-another-device).

Fozria (pronounced FOZ-ree-uh) was called Fozzie during early development;
you may still see the old name in URLs, package names and settings.

## What you need

- **Docker.** Docker Desktop on macOS or Windows, or Docker Engine on
  Linux. It needs Docker Compose **v2.20.0 or newer**: check with
  `docker compose version`.
- **An app.functionberry.com account** (Mark invites you).
  Fozria's images are on `registry.functionberry.com`, and access is per
  account.
- **About 2 GB of free disk** for the images, plus whatever your data
  grows to.

## Getting access

1. Mark sends you an invite to <https://app.functionberry.com>. Accept it
   and create your account.
2. Mark adds you to the **Release testers** group. Until he has, the
   installer can log in but can't download Fozria.

## The install command

The easiest way to install: on app.functionberry.com open **Your settings
→ Install Fozria on your machine**, press the button, copy the command,
and paste it in a terminal (macOS, Linux, or Windows via WSL). It looks
like this:

```sh
curl -fsSL https://releases.functionberry.com/install.sh | bash -s -- --code K7QX-M2PD-9WFA
```

The code in it works once, for a short time. The installer swaps it for
a download-only API token, logs in to `registry.functionberry.com` with
it, and saves the token in the install's `.env` (never the code). If the
code has expired or was already used, press the button again for a new
command. You can add other options after the code, for example
`--name second --core-port 4010 --dashboard-port 5183`.

## Creating an API token

If you'd rather not use the install command, the installer can log in to
`registry.functionberry.com` with your app.functionberry.com account's
email and an **API token** (your account password won't work). To make
one:

1. Sign in at <https://app.functionberry.com>.
2. Open **Your settings → API tokens** and create a token.
3. Copy it when it's shown: it's only shown once. It's 64 characters,
   digits and the letters a to f.

Pick whatever expiry you're happy with. When it expires, make a new one
and re-run the installer.

### Already testing with a GitHub token?

Fozria's downloads are moving from GitHub's registry (`ghcr.io`) to
`registry.functionberry.com`. When you re-run the installer in a
terminal, it now offers to switch your install to your
app.functionberry.com account. The easiest way is to run the command from
**Your settings → Install Fozria on your machine** instead (see
[The install command](#the-install-command)); or say yes and enter your
app.functionberry.com email and API token (see
[Moving an existing install](#moving-an-existing-install)). If you say
no, or run it with `--yes`, it carries on with `ghcr.io` as before, and
your GitHub token keeps working until those downloads are retired. If it
expires before you switch, create a new
**classic** token with only `read:packages` ticked at
<https://github.com/settings/tokens/new?scopes=read:packages&description=Fozzie%20beta>,
and re-run the installer.

## Installing

On app.functionberry.com open **Your settings → Install Fozria on your
machine**, press the button, copy the command, and paste it in a terminal
(macOS, Linux, or Windows via WSL). See
[The install command](#the-install-command).

Or, in a terminal, run:

```sh
curl -fsSL https://releases.functionberry.com/install.sh | bash
```

It checks Docker, then asks for your app.functionberry.com email and API
token (the token isn't shown as you type; see
[Creating an API token](#creating-an-api-token)).

Either way, it downloads Fozria, starts it, and opens your browser on a
"create your account" page. The first install can take a few minutes.

Once you've signed in, you can add one of the two example projects
(Kitchen renovation, or Example: launch a simple website) from **Help →
Getting started → Add an example**, to have something to click around.

If you've already run `docker login registry.functionberry.com` yourself,
it may not need to ask. It then offers to save your email and API token
anyway: in-app updates will need them (see [Updating](#updating)). You can skip that and
add them later by re-running the installer.

To run it without any questions, add `--yes` after the install command's
code, or set the credentials in the environment and pass `--yes`:

```sh
curl -fsSL https://releases.functionberry.com/install.sh | FOZRIA_REGISTRY_USERNAME=you@example.com FOZRIA_REGISTRY_TOKEN=... bash -s -- --yes
```

## More than one instance, and other ports

By default Fozria uses ports 4000 and 5173, at <http://localhost:5173>. To
run a second, separate instance, give it a name and two free ports the
first time:

```sh
curl -fsSL https://releases.functionberry.com/install.sh | bash -s -- --name second --core-port 4010 --dashboard-port 5183
```

Later runs for that instance just need `--name second`: its ports are
remembered. Run with `--help` to see every option.

<a id="using-fozzie-from-another-device"></a>

## Using Fozria from another device

By default Fozria only answers on this computer. To open it from another
device, such as a laptop or phone, re-run the installer with
`--public-host` and this computer's name or IP address as other devices
see it:

```sh
curl -fsSL https://releases.functionberry.com/install.sh | bash -s -- --public-host officemacbook.local
```

Add `--name X` for a named instance. On the other device, open
`http://<host>:<dashboard port>`, for example
<http://officemacbook.local:5173>. Invite and password-reset emails use
that address too.

- `--public-host` on its own listens on every network interface
  (`0.0.0.0`). To listen on just one, add `--bind-address <IP>`, for
  example your Tailscale address (`tailscale ip -4` shows it; it starts
  with `100.`). With `--bind-address` and no `--public-host`, links use
  that IP.
- Only the dashboard's port is opened. core-api's port (4000) stays on
  this computer: the dashboard passes the browser's requests through to
  it.
- The choice is remembered: later runs of the installer and in-app
  updates keep it.
- `--localhost-only` switches back to this computer only.
- Your computer's firewall may need to allow incoming connections on the
  dashboard's port (5173 by default).

> **Before you turn this on.** Fozria is served over plain HTTP. On a
> local network, your password, sign-in tokens and everything else you
> send travel unencrypted, so anyone else on that network can read them.
> Only use it on a trusted home network. Anywhere else, use a private
> network such as [Tailscale](https://tailscale.com) (with
> `--bind-address` set to its `100.x` address), or put an HTTPS reverse
> proxy in front of Fozria. **Never port-forward Fozria to the
> internet.** The default stays localhost-only, and `--localhost-only`
> always takes you back to it.

The installer shows the same warning, and asks before opening the port
unless you passed `--yes`.

### On a server, at your own domain (HTTPS)

On a server reachable from the internet, with a domain name whose DNS A
record points at it, `--domain` serves Fozria at `https://<domain>`
instead:

```sh
curl -fsSL https://releases.functionberry.com/install.sh | bash -s -- --domain app.example.com
```

It adds a [Caddy](https://caddyserver.com) container that listens on
ports 80 and 443 and gets and renews a Let's Encrypt certificate by
itself. The dashboard and core-api stay on `127.0.0.1`, so only Caddy is
reachable from outside, and everything travels over HTTPS. Caddy also
adds the standard security headers, including one that tells browsers
to always use HTTPS for that domain (`--hsts subdomains` extends it to
every subdomain). Ports 80 and 443 must be free on the server and
allowed in both your cloud provider's firewall and the server's own. The
choice is remembered, and `--no-domain` switches back. The "Deploy to a server" guide in Fozria's
repository (`docs/DEPLOY_TO_A_SERVER.md`) walks through it from an empty
server.

## Where things live

Fozria installs into `~/fozzie` (or `~/fozzie-<name>` for a named
instance). That directory holds two files, three with `--domain` and five
with `--registry-domain`:

- `docker-compose.yml`, which describes the containers. The installer
  replaces it on every run.
- `.env`, which holds your instance's settings and **secrets**: its
  database password, its encryption key and **your Fozria API token**
  (or, if you're still on one, your GitHub token), which is kept there so that in-app updates can download new versions. It's
  readable only by you (`chmod 600`). Don't share it or commit it
  anywhere. The installer keeps any line you add to it, for example SMTP
  settings.
- `Caddyfile`, only with `--domain`: the settings of the Caddy container
  that serves HTTPS. The installer rewrites it on every run, and removes
  it with `--no-domain`.
- `registry-config.yml` and `registry-supervisor.sh`, only with
  `--registry-domain`: the settings and the start-up script of the
  release registry container. The installer rewrites them on every run,
  and removes them with `--no-registry` (or `--no-domain`). Its stored
  images stay in their Docker volume.

Your data itself (the database, git repositories, attachments and
backups) lives in Docker volumes, not in that directory. It can only be
opened with this `.env`: its database password and encryption key are
the ones the data was created with, and your backups are encrypted with
that key. Keep a private copy of `.env` somewhere safe.

## Updating

When a new release is out, admins see an "Update available" banner at
the top of Fozria. Click **Update** there, or in Settings → Updates, and
confirm. Fozria then:

1. takes a backup;
2. downloads the new version;
3. restarts on it, so it's unavailable for a minute or two;
4. checks that the new version started.

A progress window shows each step. You can hide it and keep using any page
you already have open. It comes back if you reload. When it says "Updated",
click **Reload** to load the new version. If the new version doesn't
start, Fozria automatically goes back to the version you had, and your data
is safe.

You can always update by re-running the same install command instead (with
`--name` if you used one). It keeps your data and settings, takes a backup
first, and then switches to the latest release. Do this if Fozria says your
version is too old to update in place, that the updater is out of date, or
that this install's compose file is out of date.

### Moving an existing install

Fozria's releases have moved to <https://releases.functionberry.com>. An
install from before the move keeps checking the old address until you
re-run the installer once from the new one (with `--name X` if you used
one):

```sh
curl -fsSL https://releases.functionberry.com/install.sh | bash
```

If your install still downloads from GitHub (`ghcr.io`), switch it to
your app.functionberry.com account. On app.functionberry.com open **Your
settings → Install Fozria on your machine**, press the button, copy the
command, and paste it in a terminal (macOS, Linux, or Windows via WSL),
adding `--name X` after the code if you used one. It switches without
asking for an email or token.

Or re-run the installer as above: it offers to switch, and if you say
yes, asks for your app.functionberry.com email and API token (see
[Creating an API token](#creating-an-api-token)). Either way it keeps
your data and settings, takes a backup first, and from then on the
install checks `releases.functionberry.com` for updates.

To do it with an API token and without any questions, read the email and
token into the environment first (the token isn't shown as you type),
then pass `--yes`. This works in bash and zsh (macOS's default shell):

```sh
printf 'app.functionberry.com email: '; read -r FOZRIA_REGISTRY_USERNAME
printf 'API token: '; read -rs FOZRIA_REGISTRY_TOKEN; echo
curl -fsSL https://releases.functionberry.com/install.sh | FOZRIA_REGISTRY_USERNAME="$FOZRIA_REGISTRY_USERNAME" FOZRIA_REGISTRY_TOKEN="$FOZRIA_REGISTRY_TOKEN" bash -s -- --yes
```

## Backups

Fozria backs itself up daily and keeps the newest 14 backups, in the
`fozzie_backups_local` Docker volume. The installer also takes one before
every update.
Settings → Backups shows when the last one ran, and whether a later one
failed (admins only).

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
docker compose -p fozzie-local --env-file .env exec --user node core-api node dist/adminCli.js reset-password you@example.com
```

It prints a link that works once, for an hour. Open it in your browser
and choose a new password. That signs the account out everywhere else and
revokes its API tokens.

If you know your password but have lost your authenticator app (and your
recovery codes), add `--reset-2fa` instead. It turns two-factor sign-in
off for that account, so you can sign in with just your password and set
it up again. It doesn't print a link or change your password:

```sh
docker compose -p fozzie-local --env-file .env exec --user node core-api node dist/adminCli.js reset-password --reset-2fa you@example.com
```

Fozria must be running: `exec` needs the `core-api` container up. If it
isn't, start Fozria first (see [Stopping and starting](#stopping-and-starting)).

Anyone with a terminal on this computer can do this, so it works even when
you're the only admin.

## Stopping and starting

```sh
cd ~/fozzie
docker compose -p fozzie-local --env-file .env stop    # stop
docker compose -p fozzie-local --env-file .env up -d   # start again
```

Fozria also starts by itself when Docker does, until you stop it.

## Uninstalling

There are two ways to uninstall, and they're very different. The
installer can ask you which one you want and do it for you (add
`--name` if you used one):

```sh
curl -fsSL https://releases.functionberry.com/install.sh | bash -s -- --uninstall
```

Or do it by hand:

**(a) Remove Fozria, but keep your data to reinstall later.**

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
docker logout registry.functionberry.com
```

Then revoke the API token on <https://app.functionberry.com>, under **Your
settings → API tokens**. If you used a GitHub token, also run
`docker logout ghcr.io` and revoke it at
<https://github.com/settings/tokens>.

Only delete the `~/fozzie` directory after `down -v`: deleting it after a
plain `down` leaves your data behind with nothing that can open it.

## Using a local model (Ollama)

You can use a model server running on your own computer, such as Ollama,
as an AI provider:

1. Start Ollama so Docker can reach it. By default it only accepts
   connections from your computer itself, which shuts Fozria out:

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

2. In Fozria, go to Settings → AI resources and click **Add resource**.
   Pick the **OpenAI-compatible** provider type, and set the base URL to
   `http://host.docker.internal:11434/v1`. Don't use `localhost`: Fozria's
   server runs in its own container, so to it `localhost` means that
   container, not your computer.

3. `host.docker.internal` works on Mac, Windows and Linux (Fozria's compose
   file sets it up on Linux). If listing the models fails, the error says
   what to fix.

## Agents

Agents are AI workers that pick up work you assign to them. They run in
their own containers, started by the **agent service**, which the
installer turns on by default. It uses an AI provider you supply.

To set one up:

1. In Fozria, go to **Agents** and click **Set up an agent**.
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
curl -fsSL https://releases.functionberry.com/install.sh | bash -s -- --no-agents
curl -fsSL https://releases.functionberry.com/install.sh | bash -s -- --with-agents
```

If you installed Fozria before agents shipped, re-run the installer once
to add the agent service: in-app updates don't add it. Until then, the
Agents page says "Agent service not set up on this instance" and shows
the command to run.

## Tests on your own repository

A coding task has a **Run tests** step. For your agent to test a change,
your repository has to say how its tests run. JavaScript and TypeScript
projects work best for now, because the agent's container is built
around Node.

The simplest way is a `.fozzie/test.json` file in the repository:

```json
{ "command": "npm test", "setup": "npm ci", "timeoutMinutes": 30 }
```

- `command` (required) runs from the root of the repository.
- `setup` (optional) runs first, for example to install dependencies.
- `lint` and `build` (optional) run after setup and before the tests, in
  that order, for example `npm run lint` and `npm run build`. Your agent
  also runs them after each change it makes. They're only in the file:
  the setting has no lint or build.
- `timeoutMinutes` (optional) is a whole number from 1 to 240. It
  defaults to 30.
- `paths` (optional) is a list of folders and files the tests depend on.
  A change outside them keeps an earlier test result. Leave it out unless
  you're sure: a list that's too narrow lets an old result count for
  changed code.

Any other key is an error, so a typo such as `comand` shows up rather
than quietly meaning "no command". The file can be up to 64 KB.

If you'd rather not add a file, set the command on the repository
instead:

1. Open **Repositories** and select the repository.
2. Select **Show properties panel**, the button beside its name.
3. In the **Code repo** group, select **Edit** on **Test command**,
   enter the command and select **Save**. **Test setup command** works
   the same way.

The setting's timeout is 30 minutes. **Test timeout (minutes)** can't be
edited there yet, so for a different timeout use `timeoutMinutes` in the
file. The setting has no `paths`, `lint` or `build`.

If the branch has a `.fozzie/test.json`, it's used and the setting is
ignored entirely: fields aren't mixed from both. If the file is invalid,
Fozria doesn't fall back to the setting. It shows the file's error, and
the fix is to correct the file.

**What Run tests does.** Your agent merges the latest main into its
branch, runs exactly the declared setup, lint, build and command
within the timeout,
and passes or fails on the exit code. If the tests fail, the agent adds
the fixes as new steps and runs them again. The result is recorded as
reported by the agent: Fozria doesn't yet run your tests itself to check
it. With no command declared, nothing runs, the step records "No test
command declared -- untested", and the pull request goes on to review.
With an invalid file, Run tests fails and adds one step to fix the file.

**Labels.** A pull request that no test run has checked shows one of
these, with **Why untested?** or **What does this mean?** to explain:

- **Untested: no test command**: nothing is declared, or the file is
  invalid (the explanation then shows the file's error).
- **Untested: tests haven't run**: a command is declared, but no result
  has been recorded yet.
- **Tests reported by agent (unverified)**: your agent ran the tests and
  recorded the result itself.

They show under **Merge readiness**, beside **Tests on merged tree**; on
a merged pull request's **Pull request** tab, beside its status; and on
the repository's list of pull requests. **Activity** shows "Merged
untested: no test command" or "Merged with tests reported by agent
(unverified)". Your install merges untested pull requests anyway: the
label only makes that visible.

**Your agent offers a command.** If a coding task starts on a repository
with no test command, the agent adds a `.fozzie/test.json` to the same
pull request, with a command it ran successfully. The pull request's
description says so. Reviewing and merging that pull request declares
the command. If nothing ran successfully, the agent leaves the file out
and says why.

### Files under .fozzie/

A repository can hold a few files in a `.fozzie/` folder that tell your
agents how to work on it. All of them are optional.

- `.fozzie/test.json` declares how the tests run, as described at the
  start of this section.
- `.fozzie/setup.sh` prepares the agent's environment:
  - It runs at the start of every attempt, on every step, before the
    step's work. It runs from the repository's root, with bash, as the
    agent, with the agent's own home folder, which keeps what's
    installed there between runs.
  - Use it to install toolchains into the home folder and fetch
    dependencies. Keep it safe to run again: it runs every time.
  - It has a time limit of 15 minutes by default. To change it, set
    `FOZZIE_SETUP_TIMEOUT_MINUTES` in your `.env`.
  - Its output shows in the run's activity.
  - If it fails, the attempt isn't counted against the step.
  - After 3 failures in a row, the step is parked as Blocked with "setup
    failed". Fix the script on the branch, or use **Reset environment**
    on the agent's page, then set the step back to Not started.
  - Agents may add or improve it in their pull requests.
- `.fozzie/AGENTS.md` is extra guidance for your agents, read after the
  `AGENTS.md` (or `CLAUDE.md`) at the repository's root. Fozria's
  workflow rules still win over both.

## Feedback

Email Mark at <TODO: Mark to fill in>. Screenshots, the version (shown in
Settings) and what you were doing all help.

## Troubleshooting

**Forgot your password?** See [Locked out?](#locked-out).

**"Docker isn't running."** Start Docker Desktop (or the Docker service on
Linux), wait until it says it's running, then run the installer again.

**"Docker Compose … is too old."** Update Docker Desktop, or the Compose
plugin on Linux, to one with Compose v2.20.0 or newer, then try again.

**"app.functionberry.com didn't accept that email and API token".** The
email is wrong, or the token has expired, been revoked, or isn't an API
token (your account password won't work). Make a new one (see
[Creating an API token](#creating-an-api-token)) and run the installer
again.

**"This install code has expired or was already used".** The code in the
install command only works once, for a short time. On
app.functionberry.com open **Your settings → Install Fozria on your
machine**, press the button again, and run the new command.

**"app.functionberry.com didn't recognise this install code".** Part of
the command was probably cut off when it was copied. Copy the whole
command again, or press the button for a new one.

**"Couldn't swap the install code".** The installer couldn't reach
app.functionberry.com. Check your internet connection and try again, or
log in with an API token instead (see
[Creating an API token](#creating-an-api-token)).

**"Your Fozria account isn't in Release testers".** Your token works, but
your account can't download Fozria yet. Ask Mark to add your email to
Release testers, then run the installer again.

**"Too many login attempts".** Too many tries from your network in a short
time. Wait a few minutes, then run the installer again.

The next three are for testers still on a GitHub token (see
[Already testing with a GitHub token?](#already-testing-with-a-github-token)).

**`unauthorized`, or "GitHub didn't accept that username and token".** The
username or token is wrong, or the token has expired or been revoked.
Create a new classic token with only `read:packages` ticked and run the
installer again.

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

**Can't open it from another device.** Check that:

- the device is on the same network (or the same Tailscale tailnet) as
  this computer;
- this computer's firewall allows incoming connections on the dashboard's
  port;
- you re-ran the installer with `--public-host` (see
  [Using Fozria from another device](#using-fozria-from-another-device)):
  its summary prints a "From other devices" address;
- you used the dashboard's port (5173 by default), not 4000: core-api's
  port is never opened to the network.

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
and also updates Fozria.

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
404).** The agent service and Fozria don't agree on the secret it reports
in with. Re-run the installer: it sets the secret up again for both.

**"Fozria couldn't go back on its own."** An update failed, and so did the
automatic rollback. The progress window shows the steps to fix it by hand,
in a terminal. Follow them, then check Fozria starts. If it still doesn't,
your backups are safe in their own volume (see [Backups](#backups)):
contact Mark before restoring one.
