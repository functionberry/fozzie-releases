#!/usr/bin/env bash
# Fozzie private-beta installer (ADR-0172 decision 8): a running Fozzie
# from the published release images, with nothing to clone or build.
#
# Install, or update to the latest release (the same command):
#   curl -fsSL https://functionberry.github.io/fozzie-releases/install.sh | bash
#
# A second, independent instance: give it a name and two free ports the
# first time. Later runs just need the name -- its ports are remembered.
#   curl -fsSL https://functionberry.github.io/fozzie-releases/install.sh | bash -s -- --name second --core-port 4010 --dashboard-port 5183
#
# The agent service runs by default (ADR-0215). --no-agents turns it off,
# and later runs remember that; --with-agents turns it back on.
#
# On a server with a domain name pointing at it: --domain HOST serves
# Fozzie at https://HOST through a Caddy container on ports 80 and 443,
# with automatic Let's Encrypt certificates (ADR-0277's 2026-11-19
# amendment), with the standard security headers set at the edge
# (2026-11-21 amendment; --hsts widens HSTS). Later runs remember it;
# --no-domain switches back.
#
# Switching an instance installed from source to these images, keeping
# its data: --import-env <its env file> takes its secrets and ports.
# `--help` lists every option.
#
# Removing an instance: --uninstall asks whether to keep its data (and
# the .env it needs) or delete everything.
#
# What this does, in order: checks Docker and Compose; checks that an
# existing instance's data opens with this .env's database password (if
# it doesn't, refuses, or offers to keep the data or start fresh, rather
# than generate a new password over it); reads the latest
# release's image refs from latest.env; downloads the images (ADR-0329):
# when the release is also on registry.functionberry.com, from there,
# logged in with your Fozria email and API token (asked for if they
# aren't in the environment or .env), falling back to ghcr.io only if the
# registry can't be reached; when it isn't, or the install only has a
# GitHub token so far, from ghcr.io, logging in if the images need it
# (walking you through creating a read:packages token); pulls the
# agent and orchestrator images when agents are on (carrying on without
# agents if it can't); writes docker-compose.yml and .env (chmod 600,
# secrets generated once and kept) into ~/fozzie or ~/fozzie-<name>; takes
# a backup first when it's replacing an existing version; starts
# everything (stopping the orchestrator if agents are off), waits for
# core-api to be healthy, then for the orchestrator's first heartbeat when
# agents are on, and opens your browser -- on a fresh install, with the
# one-time setup token, so you land on "create your account".

set -euo pipefail

# Pure, testable logic for the release installer, release/install.sh
# (ADR-0172 decision 8) -- argument parsing, latest.env validation, .env
# merging and Docker error mapping, exercised by scripts/test.sh. Makes no
# network or docker calls of its own: install.sh hands in what it read.
# Inlined into install.sh when it's published, because `curl | bash` has
# no file to source anything relative to. bash 3.2 safe: no mapfile, no
# ${var,,}, no associative arrays, no `sort -V`, no jq.

# Pure, testable Docker Compose version checks for install.sh -- sourced by
# install.sh and scripts/test.sh, so they can be exercised without Docker.
# Makes no docker calls of its own: install.sh hands in the raw
# `docker compose version` output.

# The oldest Docker Compose Fozzie's compose files load on. Keep in step
# with README.md's and docs/DEPLOYMENT.md's Prerequisites and the pinned
# compose binary in .github/workflows/test.yml.
FOZZIE_MIN_COMPOSE_VERSION="2.20.0"

# Given raw `docker compose version` output (e.g. "Docker Compose version
# v2.23.0", "v2.40.0", "2.23.0-desktop.1"), echoes the first
# MAJOR.MINOR.PATCH in it, or nothing if there isn't one. Always returns 0,
# so it's safe in a `$(...)` under a `set -e` caller.
compose_version_from_output() {
  local output="$1"
  printf '%s\n' "$output" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true
  return 0
}

# True (0) iff version have (MAJOR.MINOR.PATCH) is at least min, compared
# numerically part by part -- 2.3.3 < 2.20.0 and 10.0.0 > 2.20.0. Not
# `sort -V`, which not every macOS sort supports. Both arguments must be
# digits-and-dots, as compose_version_from_output echoes.
version_at_least() {
  local have="$1" min="$2"
  local h1 h2 h3 m1 m2 m3
  IFS=. read -r h1 h2 h3 <<< "$have"
  IFS=. read -r m1 m2 m3 <<< "$min"
  h1=$((10#${h1:-0})) h2=$((10#${h2:-0})) h3=$((10#${h3:-0}))
  m1=$((10#${m1:-0})) m2=$((10#${m2:-0})) m3=$((10#${m3:-0}))
  if [ "$h1" -ne "$m1" ]; then
    [ "$h1" -gt "$m1" ]
  elif [ "$h2" -ne "$m2" ]; then
    [ "$h2" -gt "$m2" ]
  else
    [ "$h3" -ge "$m3" ]
  fi
}

# Reads an orchestrator's first heartbeat out of its logs -- the wait both
# installers do after starting it: ./install.sh --with-agents (sourced via
# scripts/lib/install_agents.sh) and the release installer,
# release/install.sh (inlined via release/lib/install_lib.sh). Pure: no
# docker calls, the caller hands in `docker compose logs orchestrator`
# output. Sources nothing itself, so release_inline has nothing more to
# follow. Safe under `set -euo pipefail`, and Bash 3.2 safe (both
# installers run on macOS's /bin/bash).

# Same literal loop.sh logs on the first heartbeat core-api accepts --
# HEARTBEAT_OK_LINE in docker/orchestrator/lib.sh. scripts/test.sh asserts
# the two match, so a reword there fails here first.
INSTALL_AGENTS_HEARTBEAT_OK_LINE="Heartbeat OK -- core-api is receiving this orchestrator's status."

# Given `docker compose logs orchestrator` output from a freshly
# (re)created orchestrator, echoes:
#   refused  -- loop.sh rejected AGENT_IDENTITIES ("refusing to start");
#               under restart: unless-stopped it repeats, so it wins
#   ok       -- the last heartbeat outcome logged was a success: the
#               first-success line, or "is getting through again" (loop.sh
#               logs the first-success line only on unknown -> ok, so a
#               first failure then a recovery never shows it)
#   failing  -- the last heartbeat outcome logged was "failing (HTTP ...)"
#   off      -- the startup line says heartbeats are off
#   pending  -- none of the above yet
orchestrator_wait_state() {
  local logs="$1" last
  case "$logs" in
    *"refusing to start"*)
      echo refused
      return 0
      ;;
  esac
  last="$(printf '%s\n' "$logs" \
    | grep -F -e "$INSTALL_AGENTS_HEARTBEAT_OK_LINE" -e "is getting through again" -e "failing (HTTP" \
    | tail -n 1 || true)"
  case "$last" in
    *"failing (HTTP"*)
      echo failing
      return 0
      ;;
    ?*)
      echo ok
      return 0
      ;;
  esac
  case "$logs" in
    *"Heartbeats: off"*) echo off ;;
    *) echo pending ;;
  esac
  return 0
}

# Echoes the HTTP code from the last "Heartbeat to ... failing (HTTP <code>)"
# line in LOGS ("none" when core-api couldn't be reached at all), or
# nothing.
orchestrator_heartbeat_failure_code() {
  printf '%s\n' "$1" | sed -n 's/.*failing (HTTP \([^)]*\)).*/\1/p' | tail -n 1 || true
  return 0
}

# Character classes are spelled out rather than written as ranges, so no
# locale can widen them (in some, [A-Z] also matches lowercase letters).
INSTALL_UPPER='ABCDEFGHIJKLMNOPQRSTUVWXYZ'
INSTALL_LOWER='abcdefghijklmnopqrstuvwxyz'
INSTALL_DIGITS='0123456789'

# Same as release.sh's RELEASE_VERSION_REGEX and release.ts's canonical
# version: strict MAJOR.MINOR.PATCH, no "v", prerelease or leading zeros.
INSTALL_VERSION_REGEX='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'

# One latest.env line: an uppercase key, "=", then no whitespace at all.
INSTALL_LATEST_LINE_REGEX="^[${INSTALL_UPPER}_]+=[^[:space:]]*\$"

# A KEY in a KEY=VALUE file.
INSTALL_KEY_REGEX="^[${INSTALL_UPPER}_][${INSTALL_UPPER}${INSTALL_DIGITS}_]*\$"

# Compose project-name rules.
INSTALL_NAME_REGEX="^[${INSTALL_LOWER}${INSTALL_DIGITS}][${INSTALL_LOWER}${INSTALL_DIGITS}_-]*\$"

# What a GitHub username and a classic PAT can look like -- checked before
# either is used, so neither can inject anything into .env.
INSTALL_GHCR_USERNAME_REGEX="^[${INSTALL_UPPER}${INSTALL_LOWER}${INSTALL_DIGITS}-]+\$"
INSTALL_GHCR_TOKEN_REGEX="^[${INSTALL_UPPER}${INSTALL_LOWER}${INSTALL_DIGITS}_]+\$"

# The Fozria release registry and the app its accounts and API tokens live
# in (ADR-0322, ADR-0329).
INSTALL_FOZRIA_REGISTRY=registry.functionberry.com
INSTALL_FOZRIA_APP=app.functionberry.com
INSTALL_FOZRIA_TOKENS_WHERE="Your settings → API tokens"

# What a Fozria account's email and an API token can look like -- checked
# before either is used, so neither can inject anything into .env. The
# email: letters, digits and . _ + - before a single @, then a dotted host
# of letters, digits and - labels. Anything it accepts also passes
# INSTALL_ENV_VALUE_REGEX. The token: 64 lowercase hex (authCredential.ts).
INSTALL_FOZRIA_USERNAME_REGEX="^[${INSTALL_UPPER}${INSTALL_LOWER}${INSTALL_DIGITS}._+-]+@[${INSTALL_UPPER}${INSTALL_LOWER}${INSTALL_DIGITS}-]+(\\.[${INSTALL_UPPER}${INSTALL_LOWER}${INSTALL_DIGITS}-]+)+\$"
INSTALL_FOZRIA_TOKEN_REGEX='^[0123456789abcdef]{64}$'

# Every value the installer writes into .env is from this set, so it's
# written unquoted and reads back the same to Compose and to
# install_env_get alike (base64 secrets, digest refs, ports, versions,
# and COMPOSE_PROFILES's comma-separated list).
INSTALL_ENV_VALUE_REGEX="^[${INSTALL_UPPER}${INSTALL_LOWER}${INSTALL_DIGITS}+/=._:@,-]+\$"

# The keys install_merge_env owns, in the order it appends them.
INSTALL_MANAGED_KEYS="FOZZIE_VERSION FOZZIE_CORE_API_IMAGE FOZZIE_DASHBOARD_IMAGE FOZZIE_UPDATER_IMAGE POSTGRES_PASSWORD FOZZIE_ENCRYPTION_KEY FOZZIE_UPDATER_TOKEN CORE_API_PORT DASHBOARD_PORT GHCR_USERNAME GHCR_TOKEN COMPOSE_PROJECT FOZZIE_INSTALL_DIR FOZZIE_AGENT_IMAGE FOZZIE_ORCHESTRATOR_IMAGE FOZZIE_ORCHESTRATOR_HEARTBEAT_SECRET FOZZIE_INSTANCE_NAME FOZZIE_AGENTS_ENABLED COMPOSE_PROFILES FOZZIE_BIND_ADDRESS FOZZIE_PUBLIC_HOST FOZZIE_DASHBOARD_URL FOZZIE_CORE_PUBLIC_URL FOZZIE_DOMAIN FOZZIE_TRUSTED_PROXY_HOPS FOZZIE_HSTS FOZZIE_REGISTRY_DOMAIN FOZZIE_REGISTRY_HTTP_SECRET FOZRIA_REGISTRY_USERNAME FOZRIA_REGISTRY_TOKEN"

INSTALL_ENV_HEADER="# Managed by the Fozzie installer: it rewrites the keys it manages on every run and keeps every other line. Holds secrets -- keep it private."

INSTALL_PAT_URL="https://github.com/settings/tokens/new?scopes=read:packages&description=Fozzie%20beta"

# The usage text, for --help and for a bad argument.
install_usage() {
  cat <<'USAGE'
Usage: install.sh [options]

  curl -fsSL https://functionberry.github.io/fozzie-releases/install.sh | bash
  curl -fsSL https://functionberry.github.io/fozzie-releases/install.sh | bash -s -- [options]

Installs Fozzie from the published release images, or updates an existing
install to the latest release. Re-running it is safe: secrets and data are
kept.

Options:
  --name NAME             Instance name (default: local). A named instance
                          lives in ~/fozzie-NAME and runs as its own
                          Compose project, fozzie-NAME.
  --core-port PORT        core-api's port on this machine (default 4000).
  --dashboard-port PORT   The dashboard's port on this machine (default 5173).
                          A named instance's first install needs both.
  --dir DIR               Install directory (default ~/fozzie or ~/fozzie-NAME).
  --import-env FILE       Take POSTGRES_PASSWORD, FOZZIE_ENCRYPTION_KEY and the
                          ports from FILE, to switch an instance installed
                          from source to these images while keeping its data.
  --no-agents             Don't run the agent service (it's on by default).
                          Remembered: later runs keep it off.
  --with-agents           Turn the agent service back on after --no-agents.
  --public-host HOST      Open the dashboard to your network, reachable from
                          other devices at http://HOST:<dashboard port>
                          (HOST is this machine's name or IP, e.g.
                          officemacbook.local). On its own it listens on
                          every interface (0.0.0.0). Emailed links use HOST.
  --bind-address ADDR     The IPv4 address the dashboard listens on, e.g.
                          Tailscale's 100.x address, or 0.0.0.0 for every
                          interface (default 127.0.0.1: this machine only).
  --localhost-only        Switch back to this machine only (the default).
                          Only the dashboard's port is ever opened to the
                          network; core-api's stays local. The choice is
                          remembered by later runs and updates. Plain HTTP:
                          read "Using Fozzie from another device" in the
                          tester guide first.
  --domain HOST           Serve Fozzie at https://HOST, with automatic Let's
                          Encrypt certificates, through a Caddy container
                          on ports 80 and 443. Those ports must be free and
                          reachable from the internet, and HOST's DNS A
                          record must point at this machine. The dashboard
                          and core-api stay on 127.0.0.1. Remembered by
                          later runs and updates.
  --hsts MODE             With --domain: how far browsers are told to
                          always use HTTPS (HSTS, for a year). host (the
                          default) covers just the domain; subdomains adds
                          every subdomain of it; preload also asks to be
                          built into browsers -- every subdomain of the
                          registered domain, and very slow to undo.
                          Remembered by later runs and updates.
  --no-domain             Stop serving at the domain: removes the Caddy
                          container (keeping its certificates) and goes
                          back to this machine only.
  --registry-domain HOST  Also serve a release registry at https://HOST,
                          through the same Caddy on ports 80 and 443.
                          Needs --domain (or a remembered domain) and a
                          different HOST, whose DNS A record must point at
                          this machine. Pulls and pushes need a Fozria API
                          token. Remembered by later runs and updates.
  --no-registry           Stop serving the release registry: removes its
                          container and its two files, keeping the volume
                          with its stored images.
  --uninstall             Remove this instance: asks whether to keep its data
                          (and .env, which that data needs) or delete
                          everything. Needs a terminal; --yes doesn't skip it.
  --yes, -y               Don't ask for confirmation.
  --help, -h              Show this help.

Environment:
  FOZRIA_REGISTRY_USERNAME, FOZRIA_REGISTRY_TOKEN
                              Your Fozria account's email and an API token
                              from app.functionberry.com (Your settings →
                              API tokens), to log in to
                              registry.functionberry.com without being
                              asked.
  GHCR_USERNAME, GHCR_TOKEN   Your GitHub username and read:packages token,
                              to log in to ghcr.io without being asked: for
                              existing testers still on a GitHub token, and
                              older releases that are only on ghcr.io.
USAGE
}

# True (0) iff name is a valid instance name: lowercase letters, digits,
# "_" and "-", starting with a letter or digit (Compose project-name
# rules, since the project is fozzie-<name>).
install_valid_name() {
  [[ "$1" =~ $INSTALL_NAME_REGEX ]]
}

# True (0) iff the database password can go into DATABASE_URL as-is --
# docker-compose.yml pastes it into postgres://fozzie:<password>@postgres
# with no escaping, so it may only use what RFC 3986 allows unescaped in
# a URL's userinfo: unreserved characters and sub-delims. 0.1.0's
# installer generated it with `openssl rand -base64`, and a "/" in that
# ended the host early -- "invalid port number" on roughly 40% of fresh
# installs (found live 2026-10-27). It's hex now.
INSTALL_URL_SAFE_PASSWORD_REGEX="^[A-Za-z0-9._~!\$&'()*+,;=-]+$"
install_url_safe_password() {
  [[ "$1" =~ $INSTALL_URL_SAFE_PASSWORD_REGEX ]]
}

# True (0) iff port is an integer from 1 to 65535, with no leading zero.
install_valid_port() {
  [[ "$1" =~ ^[123456789][0123456789]{0,4}$ ]] && [ "$1" -le 65535 ]
}

# One IPv4 octet: 0 to 255, no leading zero except a lone 0.
INSTALL_IPV4_OCTET_REGEX='^(0|[123456789][0123456789]{0,2})$'

# True (0) iff addr is a dotted-quad IPv4 address: four octets from 0 to
# 255, no leading zeros except a lone 0. IPv6, and anything with a colon
# (a port), is rejected.
install_valid_ipv4() {
  local addr="$1" rest octet n=0
  case "$addr" in
    "" | .* | *. | *..*) return 1 ;;
  esac
  rest="$addr."
  while [ -n "$rest" ]; do
    octet="${rest%%.*}"
    rest="${rest#*.}"
    n=$((n + 1))
    [ "$n" -le 4 ] || return 1
    [[ "$octet" =~ $INSTALL_IPV4_OCTET_REGEX ]] || return 1
    [ "$octet" -le 255 ] || return 1
  done
  [ "$n" -eq 4 ]
}

# True (0) iff addr is an IPv4 loopback address (127.x.x.x).
install_is_loopback() {
  case "$1" in
    127.*) return 0 ;;
  esac
  return 1
}

# One hostname label: letters, digits and "-", 1 to 63 characters, not
# starting or ending with "-".
INSTALL_HOST_LABEL_REGEX="^[${INSTALL_UPPER}${INSTALL_LOWER}${INSTALL_DIGITS}]([${INSTALL_UPPER}${INSTALL_LOWER}${INSTALL_DIGITS}-]{0,61}[${INSTALL_UPPER}${INSTALL_LOWER}${INSTALL_DIGITS}])?\$"

INSTALL_ALL_DIGITS_REGEX="^[${INSTALL_DIGITS}]+\$"

# True (0) iff host is what --public-host takes: an IPv4 address or a
# hostname -- dot-separated labels (INSTALL_HOST_LABEL_REGEX), at most 253
# characters in all. No scheme, port, path, "_" or whitespace, so it's
# safe in .env unquoted and in a URL as-is.
install_valid_public_host() {
  local host="$1" rest label
  install_valid_ipv4 "$host" && return 0
  [ -n "$host" ] || return 1
  [ "${#host}" -le 253 ] || return 1
  case "$host" in
    .* | *. | *..*) return 1 ;;
  esac
  rest="$host."
  while [ -n "$rest" ]; do
    label="${rest%%.*}"
    rest="${rest#*.}"
    [[ "$label" =~ $INSTALL_HOST_LABEL_REGEX ]] || return 1
  done
  # An all-digit last label is a mistyped IPv4 address (256.1.1.1,
  # 1.2.3), not a hostname: no top-level domain is all digits.
  ! [[ "$label" =~ $INSTALL_ALL_DIGITS_REGEX ]]
}

# True (0) iff host is what --domain takes: a public DNS name Let's
# Encrypt can issue a certificate for. It passes install_valid_public_host,
# isn't an IPv4 address, has at least one dot, and isn't localhost,
# *.localhost or *.local (mDNS names never resolve publicly). Compared
# case-insensitively; install_parse_args stores it lowercased.
install_valid_domain() {
  local host
  host="$(install_lower "$1")"
  install_valid_public_host "$host" || return 1
  install_valid_ipv4 "$host" && return 1
  case "$host" in
    *.*) ;;
    *) return 1 ;;
  esac
  case "$host" in
    localhost | *.localhost | *.local) return 1 ;;
  esac
  return 0
}

# The Compose project for an instance name: fozzie-<name>, so the default
# "local" instance is fozzie-local -- the same as the source-built
# install's.
install_project_for_name() {
  printf 'fozzie-%s\n' "$1"
}

# The default install directory for an instance name under home: ~/fozzie
# for "local", ~/fozzie-<name> otherwise.
install_default_dir() {
  local name="$1" home="$2"
  if [ "$name" = "local" ]; then
    printf '%s/fozzie\n' "$home"
  else
    printf '%s/fozzie-%s\n' "$home" "$name"
  fi
}

# Parses install.sh's arguments into INSTALL_NAME, INSTALL_PROJECT,
# INSTALL_DIR, INSTALL_CORE_PORT, INSTALL_DASHBOARD_PORT,
# INSTALL_IMPORT_ENV, INSTALL_YES, INSTALL_HELP, INSTALL_UNINSTALL and
# INSTALL_LOCALHOST_ONLY (true/false), INSTALL_AGENTS (on for
# --with-agents, off for --no-agents, "" for neither), and
# INSTALL_BIND_ADDRESS and INSTALL_PUBLIC_HOST ("" when not given; see
# install_network_wanted, ADR-0277), INSTALL_DOMAIN (--domain, lowercased,
# "" when not given) and INSTALL_NO_DOMAIN (true/false; see
# install_domain_wanted, ADR-0277's 2026-11-19 amendment) and INSTALL_HSTS
# (--hsts: host, subdomains or preload, "" when not given; see
# install_hsts_wanted, ADR-0277's 2026-11-21 amendment), and
# INSTALL_REGISTRY_DOMAIN (--registry-domain, lowercased, "" when not
# given) and INSTALL_NO_REGISTRY (true/false; see
# install_registry_domain_wanted, ADR-0325). Takes both "--flag value"
# and "--flag=value". An unknown flag, a missing value, an invalid name,
# port, bind address, public host, domain, registry domain or HSTS mode,
# both agent flags at once, or network flags that contradict each other
# (--localhost-only with --bind-address or --public-host; a loopback
# --bind-address with --public-host; --domain, --hsts or
# --registry-domain with --no-domain, --localhost-only, --bind-address or
# --public-host; --registry-domain with --no-registry, or equal to
# --domain) prints why and the usage to stderr and returns 1. INSTALL_DIR
# defaults from $HOME.
install_parse_args() {
  local flag value
  INSTALL_NAME=local
  INSTALL_PROJECT=""
  INSTALL_DIR=""
  INSTALL_CORE_PORT=""
  INSTALL_DASHBOARD_PORT=""
  INSTALL_IMPORT_ENV=""
  INSTALL_YES=false
  INSTALL_HELP=false
  INSTALL_UNINSTALL=false
  INSTALL_AGENTS=""
  INSTALL_BIND_ADDRESS=""
  INSTALL_PUBLIC_HOST=""
  INSTALL_LOCALHOST_ONLY=false
  INSTALL_DOMAIN=""
  INSTALL_NO_DOMAIN=false
  INSTALL_HSTS=""
  INSTALL_REGISTRY_DOMAIN=""
  INSTALL_NO_REGISTRY=false
  local agent_flag=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help | -h)
        INSTALL_HELP=true
        shift
        continue
        ;;
      --yes | -y)
        INSTALL_YES=true
        shift
        continue
        ;;
      --uninstall)
        INSTALL_UNINSTALL=true
        shift
        continue
        ;;
      --localhost-only)
        INSTALL_LOCALHOST_ONLY=true
        shift
        continue
        ;;
      --no-domain)
        INSTALL_NO_DOMAIN=true
        shift
        continue
        ;;
      --no-registry)
        INSTALL_NO_REGISTRY=true
        shift
        continue
        ;;
      --no-agents | --with-agents)
        if [ -n "$agent_flag" ] && [ "$agent_flag" != "$1" ]; then
          printf '%s and %s contradict each other -- pick one.\n\n' "$agent_flag" "$1" >&2
          install_usage >&2
          return 1
        fi
        agent_flag="$1"
        if [ "$1" = --no-agents ]; then
          INSTALL_AGENTS=off
        else
          INSTALL_AGENTS=on
        fi
        shift
        continue
        ;;
      --name=* | --core-port=* | --dashboard-port=* | --import-env=* | --dir=* | --bind-address=* | --public-host=* | --domain=* | --hsts=* | --registry-domain=*)
        flag="${1%%=*}"
        value="${1#*=}"
        shift
        ;;
      --name | --core-port | --dashboard-port | --import-env | --dir | --bind-address | --public-host | --domain | --hsts | --registry-domain)
        flag="$1"
        if [ "$#" -lt 2 ]; then
          value=""
        else
          value="$2"
        fi
        case "$value" in
          -*) value="" ;;
        esac
        if [ -n "$value" ]; then
          shift 2
        else
          shift
        fi
        ;;
      *)
        printf 'Unknown option: %s\n\n' "$1" >&2
        install_usage >&2
        return 1
        ;;
    esac
    if [ -z "$value" ]; then
      printf '%s needs a value.\n\n' "$flag" >&2
      install_usage >&2
      return 1
    fi
    case "$flag" in
      --name)
        if ! install_valid_name "$value"; then
          printf 'Invalid --name "%s": use lowercase letters, digits, "_" and "-", starting with a letter or digit.\n' "$value" >&2
          return 1
        fi
        INSTALL_NAME="$value"
        ;;
      --core-port | --dashboard-port)
        if ! install_valid_port "$value"; then
          printf 'Invalid %s "%s": it must be a port number from 1 to 65535.\n' "$flag" "$value" >&2
          return 1
        fi
        if [ "$flag" = "--core-port" ]; then
          INSTALL_CORE_PORT="$value"
        else
          INSTALL_DASHBOARD_PORT="$value"
        fi
        ;;
      --bind-address)
        if ! install_valid_ipv4 "$value"; then
          printf 'Invalid --bind-address "%s": it must be an IPv4 address such as 0.0.0.0 (every interface) or 100.64.0.5 -- no host names, IPv6 or port.\n' "$value" >&2
          return 1
        fi
        INSTALL_BIND_ADDRESS="$value"
        ;;
      --public-host)
        if ! install_valid_public_host "$value"; then
          printf 'Invalid --public-host "%s": give just a host name or IPv4 address, such as officemacbook.local or 192.168.1.20 -- no http://, port or path.\n' "$value" >&2
          return 1
        fi
        INSTALL_PUBLIC_HOST="$value"
        ;;
      --domain)
        if ! install_valid_domain "$value"; then
          printf 'Invalid --domain "%s": give a public DNS name such as app.example.com -- not an IP address, localhost, http:// or a port.\n' "$value" >&2
          return 1
        fi
        INSTALL_DOMAIN="$(install_lower "$value")"
        ;;
      --registry-domain)
        if ! install_valid_domain "$value"; then
          printf 'Invalid --registry-domain "%s": give a public DNS name such as registry.example.com -- not an IP address, localhost, http:// or a port.\n' "$value" >&2
          return 1
        fi
        INSTALL_REGISTRY_DOMAIN="$(install_lower "$value")"
        ;;
      --hsts)
        if ! install_valid_hsts "$value"; then
          printf 'Invalid --hsts "%s": use host (the default: just the domain), subdomains or preload.\n' "$value" >&2
          return 1
        fi
        INSTALL_HSTS="$value"
        ;;
      --import-env) INSTALL_IMPORT_ENV="$value" ;;
      --dir) INSTALL_DIR="$value" ;;
    esac
  done
  if [ "$INSTALL_LOCALHOST_ONLY" = true ]; then
    if [ -n "$INSTALL_BIND_ADDRESS" ]; then
      printf -- '--localhost-only and --bind-address contradict each other -- pick one.\n\n' >&2
      install_usage >&2
      return 1
    fi
    if [ -n "$INSTALL_PUBLIC_HOST" ]; then
      printf -- '--localhost-only and --public-host contradict each other -- pick one.\n\n' >&2
      install_usage >&2
      return 1
    fi
  fi
  if [ -n "$INSTALL_PUBLIC_HOST" ] && install_is_loopback "$INSTALL_BIND_ADDRESS"; then
    printf -- '--bind-address %s and --public-host contradict each other -- pick one: %s keeps Fozzie on this machine only.\n\n' "$INSTALL_BIND_ADDRESS" "$INSTALL_BIND_ADDRESS" >&2
    install_usage >&2
    return 1
  fi
  if [ -n "$INSTALL_REGISTRY_DOMAIN" ] && [ "$INSTALL_NO_REGISTRY" = true ]; then
    printf -- '--registry-domain and --no-registry contradict each other -- pick one.\n\n' >&2
    install_usage >&2
    return 1
  fi
  for value in --domain --hsts --registry-domain; do
    case "$value" in
      --domain) [ -n "$INSTALL_DOMAIN" ] || continue ;;
      --hsts) [ -n "$INSTALL_HSTS" ] || continue ;;
      --registry-domain) [ -n "$INSTALL_REGISTRY_DOMAIN" ] || continue ;;
    esac
    flag=""
    if [ "$INSTALL_NO_DOMAIN" = true ]; then
      flag=--no-domain
    elif [ "$INSTALL_LOCALHOST_ONLY" = true ]; then
      flag=--localhost-only
    elif [ -n "$INSTALL_BIND_ADDRESS" ]; then
      flag=--bind-address
    elif [ -n "$INSTALL_PUBLIC_HOST" ]; then
      flag=--public-host
    fi
    if [ -n "$flag" ]; then
      if [ "$value" = --domain ]; then
        printf -- '--domain and %s contradict each other -- pick one.\n\n' "$flag" >&2
      elif [ "$value" = --registry-domain ]; then
        printf -- "--registry-domain and %s contradict each other -- the registry needs the app's --domain.\n\n" "$flag" >&2
      else
        printf -- '--hsts and %s contradict each other -- --hsts only applies with --domain.\n\n' "$flag" >&2
      fi
      install_usage >&2
      return 1
    fi
  done
  if [ -n "$INSTALL_REGISTRY_DOMAIN" ] && [ "$INSTALL_REGISTRY_DOMAIN" = "$INSTALL_DOMAIN" ]; then
    printf -- "--registry-domain must differ from --domain -- the registry is its own site.\n\n" >&2
    install_usage >&2
    return 1
  fi
  INSTALL_PROJECT="$(install_project_for_name "$INSTALL_NAME")"
  if [ -z "$INSTALL_DIR" ]; then
    if [ -z "${HOME:-}" ]; then
      printf 'HOME is not set -- pass --dir.\n' >&2
      return 1
    fi
    INSTALL_DIR="$(install_default_dir "$INSTALL_NAME" "$HOME")"
  fi
  return 0
}

# True (0) iff this run must refuse for want of ports: a named instance's
# first install (no existing .env with ports, no --import-env with ports)
# with --core-port and --dashboard-port not both given -- there's no safe
# default to guess, and 4000/5173 would collide with the default
# instance. "local" always has its defaults. have_existing and have_import
# are true/false.
install_needs_ports() {
  local name="$1" have_existing="$2" have_import="$3" core="$4" dash="$5"
  [ "$name" != "local" ] || return 1
  [ "$have_existing" != true ] || return 1
  [ "$have_import" != true ] || return 1
  [ -z "$core" ] || [ -z "$dash" ]
}

# Echoes true or false: whether this install should run the agent service.
# FLAG is INSTALL_AGENTS (on, off or ""): a flag wins. Otherwise the
# choice remembered in EXISTING_ENV's FOZZIE_AGENTS_ENABLED (exactly true
# or false) stands, and with neither it's true -- agents are on by
# default, including on an install from before they existed. Always
# returns 0.
#   install_agents_wanted EXISTING_ENV FLAG
install_agents_wanted() {
  case "$2" in
    on)
      echo true
      return 0
      ;;
    off)
      echo false
      return 0
      ;;
  esac
  case "$(install_env_get "$1" FOZZIE_AGENTS_ENABLED)" in
    false) echo false ;;
    *) echo true ;;
  esac
  return 0
}

# Echoes the domain this install should serve at over HTTPS through the
# caddy service (ADR-0277's 2026-11-19 amendment), or "" for none.
# FLAG_DOMAIN is INSTALL_DOMAIN (already validated and lowercased),
# NO_DOMAIN is INSTALL_NO_DOMAIN, and OTHER_NET_FLAG is true when this run
# gave --localhost-only, --bind-address or --public-host. In order:
#   --domain: that domain;
#   --no-domain, or any other network flag (each replaces the domain
#     setup): none;
#   otherwise EXISTING_ENV's FOZZIE_DOMAIN if it's still valid, so a
#     re-run without --domain keeps it (and in-app updates never rewrite
#     it).
# Always returns 0.
#   install_domain_wanted EXISTING_ENV FLAG_DOMAIN NO_DOMAIN OTHER_NET_FLAG
install_domain_wanted() {
  local existing="$1" flag_domain="$2" no_domain="${3:-false}" other_net="${4:-false}"
  local domain
  if [ -n "$flag_domain" ]; then
    echo "$flag_domain"
    return 0
  fi
  if [ "$no_domain" = true ] || [ "$other_net" = true ]; then
    echo ""
    return 0
  fi
  domain="$(install_lower "$(install_env_get "$existing" FOZZIE_DOMAIN)")"
  install_valid_domain "$domain" || domain=""
  echo "$domain"
  return 0
}

# Echoes the domain this install should serve its release registry at
# (ADR-0325), or "" for none. FLAG_REGISTRY_DOMAIN is
# INSTALL_REGISTRY_DOMAIN (already validated and lowercased), NO_REGISTRY
# is INSTALL_NO_REGISTRY and DOMAIN is install_domain_wanted's answer. In
# order:
#   no DOMAIN: none -- the token realm is on the app's domain, behind the
#     same Caddy, so --no-domain or any other network flag drops the
#     registry too;
#   --registry-domain: that domain;
#   --no-registry: none;
#   otherwise EXISTING_ENV's FOZZIE_REGISTRY_DOMAIN, lowercased, if it's
#     still valid and differs from DOMAIN, so a re-run keeps it (and
#     in-app updates never rewrite it).
# Always returns 0.
#   install_registry_domain_wanted EXISTING_ENV FLAG_REGISTRY_DOMAIN NO_REGISTRY DOMAIN
install_registry_domain_wanted() {
  local existing="$1" flag="$2" no_registry="${3:-false}" domain="$4"
  local registry
  if [ -z "$domain" ]; then
    echo ""
    return 0
  fi
  if [ -n "$flag" ]; then
    echo "$flag"
    return 0
  fi
  if [ "$no_registry" = true ]; then
    echo ""
    return 0
  fi
  registry="$(install_lower "$(install_env_get "$existing" FOZZIE_REGISTRY_DOMAIN)")"
  if ! install_valid_domain "$registry" || [ "$registry" = "$domain" ]; then
    registry=""
  fi
  echo "$registry"
  return 0
}

# True (0) iff mode is an --hsts mode: host, subdomains or preload.
install_valid_hsts() {
  case "$1" in
    host | subdomains | preload) return 0 ;;
  esac
  return 1
}

# Echoes the HSTS mode this install should send (ADR-0277's 2026-11-21
# amendment): host, subdomains or preload, or "" when DOMAIN (from
# install_domain_wanted) is "" -- HSTS only exists at a domain. FLAG_HSTS
# is INSTALL_HSTS (already validated); with none, EXISTING_ENV's
# FOZZIE_HSTS if it's still a valid mode, else host. Always returns 0.
#   install_hsts_wanted EXISTING_ENV FLAG_HSTS DOMAIN
install_hsts_wanted() {
  local existing="$1" flag="$2" domain="$3" mode
  if [ -z "$domain" ]; then
    echo ""
    return 0
  fi
  mode="$flag"
  if [ -z "$mode" ]; then
    mode="$(install_env_get "$existing" FOZZIE_HSTS)"
    install_valid_hsts "$mode" || mode=host
  fi
  echo "$mode"
  return 0
}

# Echoes the Strict-Transport-Security value for an HSTS mode: a year
# (31536000 seconds) for host or "", plus includeSubDomains for
# subdomains, plus preload for preload (hstspreload.org requires
# includeSubDomains and at least a year with preload). Returns 1 for any
# other mode.
install_hsts_value() {
  case "$1" in
    "" | host) echo "max-age=31536000" ;;
    subdomains) echo "max-age=31536000; includeSubDomains" ;;
    preload) echo "max-age=31536000; includeSubDomains; preload" ;;
    *) return 1 ;;
  esac
}

# Prints the Caddyfile the caddy service runs with --domain (ADR-0277's
# 2026-11-21 amendment), which install.sh writes to <install dir>/Caddyfile
# on every run. A bare site address keeps what `caddy reverse-proxy` did:
# automatic HTTPS, the HTTP->HTTPS redirect, and reverse_proxy passing the
# original Host through. On top, the standard security headers -- each
# "?", so it's only set when the response doesn't already have it (the
# app's own, stricter headers, such as an attachment's sandbox CSP, win)
# -- and Server, Via and X-Powered-By removed. DOMAIN must already pass
# install_valid_domain, so writing it as is can't inject anything.
# HSTS_MODE is install_hsts_wanted's answer. With REGISTRY_DOMAIN
# (install_registry_domain_wanted's answer, ADR-0325), an empty line and
# a second site follow: the same headers and HSTS, proxying to the
# registry service. It has no request_body limit (image layers are big)
# and needs no trusted_proxies (the registry trusts no forwarded
# headers). Without it the output is exactly the one-site file. Returns 1
# for a bad mode.
#   install_caddyfile DOMAIN HSTS_MODE [REGISTRY_DOMAIN]
install_caddyfile() {
  local domain="$1" hsts registry="${3:-}"
  hsts="$(install_hsts_value "$2")" || return 1
  printf '%s\n' "# Managed by the Fozzie installer (--domain): rewritten on every run, so edits here are overwritten."
  install_caddy_site "$domain" "$hsts" dashboard:5173
  if [ -n "$registry" ]; then
    printf '\n'
    install_caddy_site "$registry" "$hsts" registry:5000
  fi
}

# Prints one Caddyfile site block for install_caddyfile: the site
# address, the security headers with HSTS value HSTS, and a
# reverse_proxy to UPSTREAM.
#   install_caddy_site SITE HSTS UPSTREAM
install_caddy_site() {
  local site="$1" hsts="$2" upstream="$3"
  printf '%s\n' \
    "$site {" \
    $'\theader {' \
    $'\t\t?Strict-Transport-Security "'"$hsts"'"' \
    $'\t\t?X-Content-Type-Options "nosniff"' \
    $'\t\t?X-Frame-Options "DENY"' \
    $'\t\t?Content-Security-Policy "frame-ancestors \'none\'"' \
    $'\t\t?Referrer-Policy "strict-origin-when-cross-origin"' \
    $'\t\t?Permissions-Policy "camera=(), microphone=(), geolocation=()"' \
    $'\t\t-Server' \
    $'\t\t-Via' \
    $'\t\t-X-Powered-By' \
    $'\t}' \
    $'\treverse_proxy '"$upstream" \
    "}"
}

# Prints the release registry's config (ADR-0325), which install.sh
# writes to <install dir>/registry-config.yml with --registry-domain. The
# registry container's supervisor (install_registry_supervisor) copies
# it to /run/fozzie-registry/config.yml, switching the one
# "enabled: false" line -- storage.maintenance.readonly's -- to true when
# disk runs low, so that line must stay the only one. Token auth
# (ADR-0322): every request needs a token from the app's realm, so
# nothing is anonymous. delete is enabled for retention and GC; the token
# service itself never grants it. http.secret isn't here: it comes from
# REGISTRY_HTTP_SECRET in the environment, from .env. Both domains must
# already pass install_valid_domain.
#   install_registry_config REGISTRY_DOMAIN APP_DOMAIN
install_registry_config() {
  local registry="$1" app="$2"
  cat <<CONFIG
# Managed by the Fozzie installer (--registry-domain): rewritten on every run, so edits here are overwritten.
version: 0.1
log:
  fields:
    service: registry
storage:
  filesystem:
    rootdirectory: /var/lib/registry
  delete:
    enabled: true
  maintenance:
    uploadpurging:
      enabled: true
      age: 168h
      interval: 24h
      dryrun: false
    readonly:
      enabled: false
http:
  addr: :5000
  host: https://$registry
  headers:
    X-Content-Type-Options:
      - nosniff
auth:
  token:
    realm: https://$app/registry/token
    service: $registry
    issuer: fozria-token-service
    rootcertbundle: /run/fozzie-registry/rootcerts.pem
CONFIG
}

# Prints the supervisor that is the registry container's entrypoint
# (ADR-0325): a POSIX sh script for the registry image's busybox. It
# polls core-api for the token-signing certificate bundle (registry 2.8
# reads rootcertbundle only at start, so a new bundle means a restart),
# switches the registry to read-only when the disk is low (the same
# margin as attachments), and stops it briefly for a daily garbage
# collect. Printed from a quoted heredoc, so nothing in it expands.
install_registry_supervisor() {
  # The shebang is printed on its own: a line starting "#!" inside the
  # published install.sh would be a second shebang there.
  printf '%s\n' '#!/bin/sh'
  cat <<'SUPERVISOR'
# Managed by the Fozzie installer (--registry-domain): rewritten on every
# run, so edits here are overwritten. The release registry's supervisor
# (ADR-0325), run as the registry container's entrypoint.
set -u

log() {
  printf 'fozzie-registry-supervisor: %s
' "$*" >&2
}

# A positive integer, else the default ($2).
positive_int() {
  case "$1" in
    "" | *[!0-9]*) echo "$2" ;;
    *)
      if [ "$1" -gt 0 ] 2>/dev/null; then echo "$1"; else echo "$2"; fi
      ;;
  esac
}

# Settings, from the environment (empty or not a positive integer means
# the default): FOZZIE_REGISTRY_CERT_POLL_SECONDS (300),
# FOZZIE_REGISTRY_GC_INTERVAL_SECONDS (86400; 0 turns GC off), and the
# disk margin shared with attachments, FOZZIE_ATTACHMENT_MIN_FREE_PERCENT
# (10, at most 100) and FOZZIE_ATTACHMENT_MIN_FREE_MB (2048). The paths
# and URL are overridable for tests, as is
# FOZZIE_REGISTRY_SUPERVISOR_ITERATIONS (unset: poll forever).
SOURCE="${FOZZIE_REGISTRY_CONFIG_SOURCE:-/fozzie/registry-config.yml}"
RUN="${FOZZIE_REGISTRY_RUN_DIR:-/run/fozzie-registry}"
DATA="${FOZZIE_REGISTRY_DATA_DIR:-/var/lib/registry}"
CERTS_URL="${FOZZIE_REGISTRY_CERTS_URL:-http://core-api:4000/registry/certs}"
POLL="$(positive_int "${FOZZIE_REGISTRY_CERT_POLL_SECONDS:-}" 300)"
case "${FOZZIE_REGISTRY_GC_INTERVAL_SECONDS:-}" in
  0) GC_INTERVAL=0 ;;
  *) GC_INTERVAL="$(positive_int "${FOZZIE_REGISTRY_GC_INTERVAL_SECONDS:-}" 86400)" ;;
esac
MIN_PERCENT="$(positive_int "${FOZZIE_ATTACHMENT_MIN_FREE_PERCENT:-}" 10)"
[ "$MIN_PERCENT" -le 100 ] || MIN_PERCENT=100
MIN_MB="$(positive_int "${FOZZIE_ATTACHMENT_MIN_FREE_MB:-}" 2048)"
ITERATIONS="${FOZZIE_REGISTRY_SUPERVISOR_ITERATIONS:-}"

CONFIG="$RUN/config.yml"
CERTS="$RUN/rootcerts.pem"
CHILD=""
WAITING_LOGGED=false
LOW=false

mkdir -p "$RUN" || exit 1

start_child() {
  registry serve "$CONFIG" &
  CHILD=$!
  log "registry started (pid $CHILD)"
}

stop_child() {
  if [ -n "$CHILD" ]; then
    kill -TERM "$CHILD" 2>/dev/null
    wait "$CHILD" 2>/dev/null
    CHILD=""
  fi
}

restart_child() {
  stop_child
  start_child
}

on_signal() {
  log "stopping"
  stop_child
  exit 0
}
trap on_signal TERM INT

# Fetches the certificate bundle. Returns 0 when it changed (or arrived
# for the first time) and was moved into place; 1 otherwise, keeping the
# current one.
fetch_certs() {
  rm -f "$CERTS.tmp"
  if ! wget -q -T 10 -O "$CERTS.tmp" "$CERTS_URL" 2>/dev/null     || ! [ -s "$CERTS.tmp" ]     || ! grep -q 'BEGIN CERTIFICATE' "$CERTS.tmp"; then
    rm -f "$CERTS.tmp"
    return 1
  fi
  if [ -f "$CERTS" ] && cmp -s "$CERTS.tmp" "$CERTS"; then
    rm -f "$CERTS.tmp"
    return 1
  fi
  mv -f "$CERTS.tmp" "$CERTS" || return 1
  return 0
}

# Sets LOW from df: true when available space is under
# max(total * MIN_PERCENT / 100, MIN_MB MiB). A df failure leaves LOW as
# it was.
check_disk() {
  out="$(df -Pk "$DATA" 2>/dev/null | awk 'NR==2 {print $2, $4}')" || return 0
  total="${out% *}"
  avail="${out#* }"
  case "$total" in "" | *[!0-9]*) return 0 ;; esac
  case "$avail" in "" | *[!0-9]*) return 0 ;; esac
  need=$((total * MIN_PERCENT / 100))
  floor=$((MIN_MB * 1024))
  [ "$need" -ge "$floor" ] || need="$floor"
  if [ "$avail" -lt "$need" ]; then LOW=true; else LOW=false; fi
}

# Regenerates the active config from the source. Returns 0 when it
# changed.
write_config() {
  if [ "$LOW" = true ]; then
    sed 's/enabled: false/enabled: true/' "$SOURCE" > "$CONFIG.tmp" || return 1
  else
    cat "$SOURCE" > "$CONFIG.tmp" || return 1
  fi
  if [ -f "$CONFIG" ] && cmp -s "$CONFIG.tmp" "$CONFIG"; then
    rm -f "$CONFIG.tmp"
    return 1
  fi
  mv -f "$CONFIG.tmp" "$CONFIG" || return 1
  return 0
}

garbage_collect() {
  log "garbage collect: stopping the registry briefly"
  stop_child
  registry garbage-collect "$CONFIG"
  log "garbage collect exited with status $?"
  start_child
}

last_gc="$(date +%s)"
n=0
while :; do
  certs_changed=false
  if fetch_certs; then
    certs_changed=true
  fi
  if ! [ -s "$CERTS" ]; then
    if [ "$WAITING_LOGGED" = false ]; then
      log "release registry disabled or unreachable -- enable the release registry in Fozria first (setReleaseRegistrySettings)"
      WAITING_LOGGED=true
    fi
  else
    had_config=false
    [ ! -f "$CONFIG" ] || had_config=true
    check_disk
    config_changed=false
    if write_config; then
      config_changed=true
      if [ "$LOW" = true ]; then
        log "low on disk: read-only (pulls work, pushes refused)"
      elif [ "$had_config" = true ]; then
        log "disk space recovered: read-write"
      fi
    fi
    if [ -z "$CHILD" ]; then
      start_child
    elif ! kill -0 "$CHILD" 2>/dev/null; then
      log "registry (pid $CHILD) exited unexpectedly"
      exit 1
    elif [ "$certs_changed" = true ] || [ "$config_changed" = true ]; then
      log "restarting the registry for a new certificate bundle or config"
      restart_child
    fi
    if [ "$GC_INTERVAL" -gt 0 ]; then
      now="$(date +%s)"
      if [ $((now - last_gc)) -ge "$GC_INTERVAL" ]; then
        garbage_collect
        last_gc="$now"
      fi
    fi
  fi
  n=$((n + 1))
  if [ -n "$ITERATIONS" ] && [ "$n" -ge "$ITERATIONS" ]; then
    stop_child
    exit 0
  fi
  sleep "$POLL" &
  wait $!
done
SUPERVISOR
}

# Echoes "<bind> <host>": the address the dashboard's port binds to and
# the public host name ("" for none) this install should use (ADR-0277).
# FLAG_BIND and FLAG_HOST are INSTALL_BIND_ADDRESS and INSTALL_PUBLIC_HOST
# (already validated), LOCALHOST_ONLY is INSTALL_LOCALHOST_ONLY, and
# DOMAIN is install_domain_wanted's answer ("" or absent for none). In
# order:
#   a domain: 127.0.0.1 and the domain -- only Caddy listens publicly;
#   --localhost-only: 127.0.0.1 and no host;
#   bind: the flag, else EXISTING_ENV's FOZZIE_BIND_ADDRESS if it's still a
#     valid IPv4 address, else 127.0.0.1;
#   host: the flag, else EXISTING_ENV's FOZZIE_PUBLIC_HOST if still valid;
#   but when EXISTING_ENV has a FOZZIE_DOMAIN (and DOMAIN is now ""), its
#     FOZZIE_BIND_ADDRESS and FOZZIE_PUBLIC_HOST were derived from that
#     domain and are ignored -- otherwise --no-domain would open the
#     dashboard to the network over plain HTTP at the domain's name;
#   a host with a loopback bind that wasn't given as a flag binds 0.0.0.0
#     (--public-host alone, also on a re-run of a localhost-only install);
#   a loopback bind clears the host (an explicit --bind-address 127.0.0.1).
# Always returns 0.
#   install_network_wanted EXISTING_ENV FLAG_BIND FLAG_HOST LOCALHOST_ONLY [DOMAIN]
install_network_wanted() {
  local existing="$1" flag_bind="$2" flag_host="$3" localhost_only="${4:-false}" domain="${5:-}"
  local bind host from_domain=false
  if [ -n "$domain" ]; then
    echo "127.0.0.1 $domain"
    return 0
  fi
  if [ "$localhost_only" = true ]; then
    echo "127.0.0.1 "
    return 0
  fi
  [ -z "$(install_env_get "$existing" FOZZIE_DOMAIN)" ] || from_domain=true
  bind="$flag_bind"
  if [ -z "$bind" ]; then
    bind=127.0.0.1
    if [ "$from_domain" != true ]; then
      bind="$(install_env_get "$existing" FOZZIE_BIND_ADDRESS)"
      install_valid_ipv4 "$bind" || bind=127.0.0.1
    fi
  fi
  host="$flag_host"
  if [ -z "$host" ] && [ "$from_domain" != true ]; then
    host="$(install_env_get "$existing" FOZZIE_PUBLIC_HOST)"
    install_valid_public_host "$host" || host=""
  fi
  if [ -n "$host" ] && install_is_loopback "$bind" && [ -z "$flag_bind" ]; then
    bind=0.0.0.0
  fi
  if install_is_loopback "$bind"; then
    host=""
  fi
  echo "$bind $host"
  return 0
}

# Echoes "<dashboard_url> <core_public_url>" for BIND and HOST (from
# install_network_wanted) and the final ports. With a DOMAIN, both are
# https://<domain>, no port: Caddy serves 443 and forwards to the
# dashboard, which proxies core-api's browser, federation and git routes.
# Otherwise the host links are built from is HOST, else BIND when it's a
# specific non-loopback address (a Tailscale 100.x bind with no
# --public-host), else none. With one, both URLs are
# http://<host>:<DASH_PORT>, for the same reason, and core-api's own port
# stays loopback. With none, they're the localhost defaults
# docker-compose.yml falls back to.
#   install_public_urls BIND HOST DASH_PORT CORE_PORT [DOMAIN]
install_public_urls() {
  local bind="$1" host="$2" dash="$3" core="$4" domain="${5:-}"
  if [ -n "$domain" ]; then
    echo "https://$domain https://$domain"
    return 0
  fi
  if [ -z "$host" ] && [ "$bind" != 0.0.0.0 ] && [ -n "$bind" ] && ! install_is_loopback "$bind"; then
    host="$bind"
  fi
  if [ -n "$host" ]; then
    echo "http://$host:$dash http://$host:$dash"
  else
    echo "http://localhost:$dash http://localhost:$core"
  fi
  return 0
}

# Prints the warning shown before the dashboard is opened to the network
# (ADR-0277). install.sh prints it; tests check it.
install_network_warning() {
  cat <<'WARNING'
WARNING: this opens Fozzie's dashboard to other devices on your network.
  - It's plain HTTP: on a LAN, passwords, sign-in tokens and everything
    else you send travel unencrypted, readable by anyone on that network.
  - Beyond a trusted home network, use a private network such as
    Tailscale (bind to its 100.x address with --bind-address) or put an
    HTTPS reverse proxy in front instead.
  - Never port-forward Fozzie to the internet.
  - Only the dashboard's port is opened; core-api's stays on this machine.
  - The default is localhost-only; re-run the installer with
    --localhost-only to switch back.
WARNING
}

# Prints the notice shown before --domain turns on (or changes) HTTPS
# serving through Caddy (ADR-0277's 2026-11-19 amendment). install.sh
# prints it; tests check it.
install_domain_notice() {
  cat <<'NOTICE'
NOTICE: this serves Fozzie on the internet, over HTTPS.
  - It opens ports 80 and 443 to the internet. Caddy gets and renews a
    certificate from Let's Encrypt by itself, and redirects HTTP to HTTPS.
  - Only Caddy listens publicly: the dashboard and core-api stay on
    127.0.0.1.
  - The domain's DNS A record must point at this machine, and ports 80
    and 443 must be allowed in your cloud provider's firewall (security
    list) and in the server's own firewall.
  - Re-run the installer with --no-domain to switch back.
NOTICE
}

# Prints the notice shown before --registry-domain turns on (or changes)
# the release registry (ADR-0325). install.sh prints it; tests check it.
#   install_registry_notice REGISTRY_DOMAIN
install_registry_notice() {
  printf '%s\n' \
    "NOTICE: this also serves a release registry at https://$1." \
    "  - It's on the same ports 80 and 443, through Caddy, with its own" \
    "    Let's Encrypt certificate. The registry itself publishes no port." \
    "  - Pulls and pushes need a Fozria API token. Nothing is served until" \
    "    an admin enables the release registry in Fozria." \
    "  - $1's DNS A record must point at this machine." \
    "  - Re-run the installer with --no-registry to remove it."
}

# Classifies a --domain's DNS: RESOLVED is the IPv4 addresses it resolves
# to (whitespace-separated, "" for none) and PUBLIC_IP is this machine's
# public IPv4 address ("" when it couldn't be found). Echoes one of:
#   none       it doesn't resolve (yet);
#   unknown    it resolves, but this machine's address is unknown;
#   ok         it resolves to this machine;
#   elsewhere  it resolves, but not to this machine.
#   install_domain_resolution_state RESOLVED PUBLIC_IP
install_domain_resolution_state() {
  local resolved="$1" public="$2" ip
  if [ -z "${resolved//[[:space:]]/}" ]; then
    echo none
    return 0
  fi
  if [ -z "$public" ]; then
    echo unknown
    return 0
  fi
  for ip in $resolved; do
    if [ "$ip" = "$public" ]; then
      echo ok
      return 0
    fi
  done
  echo elsewhere
  return 0
}

# The image-ref regex for one service (core-api, dashboard, updater, agent
# or orchestrator): the same pin-by-digest shape release.ts requires, on
# ghcr.io (ghcr.io/functionberry/fozzie-dist-<service>) or on the Fozria
# registry (registry.functionberry.com/fozria-dist-<service>, ADR-0329),
# since an install that pulled from the registry keeps those refs in .env.
install_image_regex() {
  printf '^(ghcr\\.io/functionberry/fozzie-dist-%s|registry\\.functionberry\\.com/fozria-dist-%s)@sha256:[0123456789abcdef]{64}$\n' "$1" "$1"
}

# The mirror-ref regex for one service (ADR-0329): its copy on the Fozria
# registry only, the same shape release.ts requires of a manifest mirror.
# A latest.env *_MIRROR line is always the registry copy, never ghcr.io.
install_mirror_regex() {
  printf '^registry\\.functionberry\\.com/fozria-dist-%s@sha256:[0123456789abcdef]{64}$\n' "$1"
}

# Validates latest.env -- given as a file path, or as its text -- without
# ever sourcing or evaluating it. Skips blank lines; rejects any other line
# that isn't KEY=VALUE with no whitespace, an unknown or duplicate key, a
# version that isn't X.Y.Z and an image ref that isn't its own service's
# digest ref. All four of FOZZIE_VERSION, FOZZIE_CORE_API_IMAGE,
# FOZZIE_DASHBOARD_IMAGE and FOZZIE_UPDATER_IMAGE are required: the
# release compose file runs the updater (manifest schema 1 itself still
# allows a release without one). FOZZIE_AGENT_IMAGE and
# FOZZIE_ORCHESTRATOR_IMAGE are optional: releases before they were
# published, and edge releases, don't have them.
# Each image may also have a FOZZIE_<SERVICE>_MIRROR (ADR-0329): its copy
# at registry.functionberry.com/fozria-dist-<service>, which needs that
# service's image line and must have the same digest.
# On success sets LATEST_VERSION, LATEST_CORE_API_IMAGE,
# LATEST_DASHBOARD_IMAGE, LATEST_UPDATER_IMAGE, LATEST_AGENT_IMAGE and
# LATEST_ORCHESTRATOR_IMAGE (the last two empty when absent), plus
# LATEST_CORE_API_MIRROR, LATEST_DASHBOARD_MIRROR, LATEST_UPDATER_MIRROR,
# LATEST_AGENT_MIRROR and LATEST_ORCHESTRATOR_MIRROR (each empty when
# absent); on failure leaves them all empty, echoes why to stderr and
# returns 1.
install_parse_latest_env() {
  local input="$1" text line key value re seen=" " n=0 mkey mirror primary
  local version="" core="" dashboard="" updater="" agent="" orchestrator=""
  local core_m="" dashboard_m="" updater_m="" agent_m="" orchestrator_m=""
  LATEST_VERSION=""
  LATEST_CORE_API_IMAGE=""
  LATEST_DASHBOARD_IMAGE=""
  LATEST_UPDATER_IMAGE=""
  LATEST_AGENT_IMAGE=""
  LATEST_ORCHESTRATOR_IMAGE=""
  LATEST_CORE_API_MIRROR=""
  LATEST_DASHBOARD_MIRROR=""
  LATEST_UPDATER_MIRROR=""
  LATEST_AGENT_MIRROR=""
  LATEST_ORCHESTRATOR_MIRROR=""
  if [ -f "$input" ]; then
    text="$(cat "$input")" || return 1
  else
    text="$input"
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    [ -n "$line" ] || continue
    if ! [[ "$line" =~ $INSTALL_LATEST_LINE_REGEX ]]; then
      printf 'latest.env line %s is not KEY=VALUE\n' "$n" >&2
      return 1
    fi
    key="${line%%=*}"
    value="${line#*=}"
    case "$seen" in
      *" $key "*)
        printf 'latest.env has %s twice\n' "$key" >&2
        return 1
        ;;
    esac
    seen="$seen$key "
    case "$key" in
      FOZZIE_VERSION)
        re="$INSTALL_VERSION_REGEX"
        version="$value"
        ;;
      FOZZIE_CORE_API_IMAGE)
        re="$(install_image_regex core-api)"
        core="$value"
        ;;
      FOZZIE_DASHBOARD_IMAGE)
        re="$(install_image_regex dashboard)"
        dashboard="$value"
        ;;
      FOZZIE_UPDATER_IMAGE)
        re="$(install_image_regex updater)"
        updater="$value"
        ;;
      FOZZIE_AGENT_IMAGE)
        re="$(install_image_regex agent)"
        agent="$value"
        ;;
      FOZZIE_ORCHESTRATOR_IMAGE)
        re="$(install_image_regex orchestrator)"
        orchestrator="$value"
        ;;
      FOZZIE_CORE_API_MIRROR)
        re="$(install_mirror_regex core-api)"
        core_m="$value"
        ;;
      FOZZIE_DASHBOARD_MIRROR)
        re="$(install_mirror_regex dashboard)"
        dashboard_m="$value"
        ;;
      FOZZIE_UPDATER_MIRROR)
        re="$(install_mirror_regex updater)"
        updater_m="$value"
        ;;
      FOZZIE_AGENT_MIRROR)
        re="$(install_mirror_regex agent)"
        agent_m="$value"
        ;;
      FOZZIE_ORCHESTRATOR_MIRROR)
        re="$(install_mirror_regex orchestrator)"
        orchestrator_m="$value"
        ;;
      *)
        printf 'latest.env has an unknown key %s\n' "$key" >&2
        return 1
        ;;
    esac
    if ! [[ "$value" =~ $re ]]; then
      printf 'latest.env %s is not valid\n' "$key" >&2
      return 1
    fi
  done <<< "$text"
  for key in FOZZIE_VERSION FOZZIE_CORE_API_IMAGE FOZZIE_DASHBOARD_IMAGE FOZZIE_UPDATER_IMAGE; do
    case "$seen" in
      *" $key "*) ;;
      *)
        printf 'latest.env has no %s\n' "$key" >&2
        return 1
        ;;
    esac
  done
  # Each mirror needs its image, at the same digest.
  for mkey in CORE_API DASHBOARD UPDATER AGENT ORCHESTRATOR; do
    case "$mkey" in
      CORE_API) mirror="$core_m" primary="$core" ;;
      DASHBOARD) mirror="$dashboard_m" primary="$dashboard" ;;
      UPDATER) mirror="$updater_m" primary="$updater" ;;
      AGENT) mirror="$agent_m" primary="$agent" ;;
      ORCHESTRATOR) mirror="$orchestrator_m" primary="$orchestrator" ;;
    esac
    [ -n "$mirror" ] || continue
    if [ -z "$primary" ]; then
      printf 'latest.env has FOZZIE_%s_MIRROR but no FOZZIE_%s_IMAGE\n' "$mkey" "$mkey" >&2
      return 1
    fi
    if [ "${mirror##*@}" != "${primary##*@}" ]; then
      printf "latest.env FOZZIE_%s_MIRROR's digest isn't FOZZIE_%s_IMAGE's\n" "$mkey" "$mkey" >&2
      return 1
    fi
  done
  LATEST_VERSION="$version"
  LATEST_CORE_API_IMAGE="$core"
  LATEST_DASHBOARD_IMAGE="$dashboard"
  LATEST_UPDATER_IMAGE="$updater"
  LATEST_AGENT_IMAGE="$agent"
  LATEST_ORCHESTRATOR_IMAGE="$orchestrator"
  # shellcheck disable=SC2034
  {
    LATEST_CORE_API_MIRROR="$core_m"
    LATEST_DASHBOARD_MIRROR="$dashboard_m"
    LATEST_UPDATER_MIRROR="$updater_m"
    LATEST_AGENT_MIRROR="$agent_m"
    LATEST_ORCHESTRATOR_MIRROR="$orchestrator_m"
  }
  return 0
}

# Echoes key's value from a KEY=VALUE file, without sourcing it: the last
# occurrence wins, one pair of surrounding single or double quotes and a
# trailing CR are stripped, and nothing else is interpreted. Echoes
# nothing when the file or the key is absent, or key isn't a KEY.
# Always returns 0, so it's safe in a `$(...)` under a `set -e` caller.
install_env_get() {
  local file="$1" key="$2" line value="" found=false
  [ -f "$file" ] || return 0
  [[ "$key" =~ $INSTALL_KEY_REGEX ]] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$key="*)
        value="${line#*=}"
        found=true
        ;;
    esac
  done < "$file"
  [ "$found" = true ] || return 0
  value="${value%$'\r'}"
  if [ "${#value}" -ge 2 ]; then
    case "$value" in
      \"*\" | \'*\')
        value="${value#?}"
        value="${value%?}"
        ;;
    esac
  fi
  printf '%s\n' "$value"
  return 0
}

# Echoes managed key's value from install_merge_env's m_<KEY> locals,
# which bash's dynamic scoping makes visible here.
install_managed_value() {
  case "$1" in
    FOZZIE_VERSION) printf '%s\n' "$m_FOZZIE_VERSION" ;;
    FOZZIE_CORE_API_IMAGE) printf '%s\n' "$m_FOZZIE_CORE_API_IMAGE" ;;
    FOZZIE_DASHBOARD_IMAGE) printf '%s\n' "$m_FOZZIE_DASHBOARD_IMAGE" ;;
    FOZZIE_UPDATER_IMAGE) printf '%s\n' "$m_FOZZIE_UPDATER_IMAGE" ;;
    POSTGRES_PASSWORD) printf '%s\n' "$m_POSTGRES_PASSWORD" ;;
    FOZZIE_ENCRYPTION_KEY) printf '%s\n' "$m_FOZZIE_ENCRYPTION_KEY" ;;
    FOZZIE_UPDATER_TOKEN) printf '%s\n' "$m_FOZZIE_UPDATER_TOKEN" ;;
    CORE_API_PORT) printf '%s\n' "$m_CORE_API_PORT" ;;
    DASHBOARD_PORT) printf '%s\n' "$m_DASHBOARD_PORT" ;;
    GHCR_USERNAME) printf '%s\n' "$m_GHCR_USERNAME" ;;
    GHCR_TOKEN) printf '%s\n' "$m_GHCR_TOKEN" ;;
    COMPOSE_PROJECT) printf '%s\n' "$m_COMPOSE_PROJECT" ;;
    FOZZIE_INSTALL_DIR) printf '%s\n' "$m_FOZZIE_INSTALL_DIR" ;;
    FOZZIE_AGENT_IMAGE) printf '%s\n' "$m_FOZZIE_AGENT_IMAGE" ;;
    FOZZIE_ORCHESTRATOR_IMAGE) printf '%s\n' "$m_FOZZIE_ORCHESTRATOR_IMAGE" ;;
    FOZZIE_ORCHESTRATOR_HEARTBEAT_SECRET) printf '%s\n' "$m_FOZZIE_ORCHESTRATOR_HEARTBEAT_SECRET" ;;
    FOZZIE_INSTANCE_NAME) printf '%s\n' "$m_FOZZIE_INSTANCE_NAME" ;;
    FOZZIE_AGENTS_ENABLED) printf '%s\n' "$m_FOZZIE_AGENTS_ENABLED" ;;
    COMPOSE_PROFILES) printf '%s\n' "$m_COMPOSE_PROFILES" ;;
    FOZZIE_BIND_ADDRESS) printf '%s\n' "$m_FOZZIE_BIND_ADDRESS" ;;
    FOZZIE_PUBLIC_HOST) printf '%s\n' "$m_FOZZIE_PUBLIC_HOST" ;;
    FOZZIE_DASHBOARD_URL) printf '%s\n' "$m_FOZZIE_DASHBOARD_URL" ;;
    FOZZIE_CORE_PUBLIC_URL) printf '%s\n' "$m_FOZZIE_CORE_PUBLIC_URL" ;;
    FOZZIE_DOMAIN) printf '%s\n' "$m_FOZZIE_DOMAIN" ;;
    FOZZIE_TRUSTED_PROXY_HOPS) printf '%s\n' "$m_FOZZIE_TRUSTED_PROXY_HOPS" ;;
    FOZZIE_HSTS) printf '%s\n' "$m_FOZZIE_HSTS" ;;
    FOZZIE_REGISTRY_DOMAIN) printf '%s\n' "$m_FOZZIE_REGISTRY_DOMAIN" ;;
    FOZZIE_REGISTRY_HTTP_SECRET) printf '%s\n' "$m_FOZZIE_REGISTRY_HTTP_SECRET" ;;
    FOZRIA_REGISTRY_USERNAME) printf '%s\n' "$m_FOZRIA_REGISTRY_USERNAME" ;;
    FOZRIA_REGISTRY_TOKEN) printf '%s\n' "$m_FOZRIA_REGISTRY_TOKEN" ;;
  esac
}

# Echoes the new .env: the existing file's lines in order, with each
# managed key (INSTALL_MANAGED_KEYS) rewritten in place at its first
# occurrence and dropped after that, every other line kept verbatim, and
# any managed key it didn't have appended. A managed key with no value is
# left out. Precedence, per key:
#   POSTGRES_PASSWORD, FOZZIE_ENCRYPTION_KEY: import, existing, candidate;
#   FOZZIE_UPDATER_TOKEN, FOZZIE_ORCHESTRATOR_HEARTBEAT_SECRET: existing,
#     candidate (never rotated: core-api and the orchestrator share it);
#   CORE_API_PORT, DASHBOARD_PORT: flag, import, existing, 4000/5173;
#   FOZZIE_VERSION, FOZZIE_*_IMAGE: always LATEST_* (install_parse_latest_env),
#     so a release without the agent or orchestrator image drops its line;
#   GHCR_USERNAME, GHCR_TOKEN: the newly entered value, existing;
#   FOZRIA_REGISTRY_USERNAME, FOZRIA_REGISTRY_TOKEN (ADR-0329): the newly
#     entered value, existing -- so an install without them keeps its .env
#     unchanged;
#   COMPOSE_PROJECT, FOZZIE_INSTALL_DIR (for the updater), and
#     FOZZIE_INSTANCE_NAME: always this run's PROJECT, absolute DIR and
#     NAME, never kept from the existing file;
#   FOZZIE_AGENTS_ENABLED: the remembered choice, install_agents_wanted
#     EXISTING FLAG_AGENTS (true or false);
#   COMPOSE_PROFILES: the comma-joined list of "agents" (when that's true
#     and AGENTS_AVAILABLE is true), "domain" (when FOZZIE_DOMAIN is set)
#     and "registry" after it (when FOZZIE_REGISTRY_DOMAIN is set) --
#     "agents", "domain", "agents,domain", "domain,registry" or
#     "agents,domain,registry" -- and left out when it's empty, so every
#     profile is off. A run that can't have agents
#     (AGENTS_AVAILABLE false: the release has no agent images, or
#     pulling them failed) doesn't write FOZZIE_AGENTS_ENABLED=false, so
#     the next release that can turns them back on.
#   FOZZIE_DOMAIN (ADR-0277's 2026-11-19 amendment): flag, else existing
#     unless --no-domain or another network flag was given
#     (install_domain_wanted EXISTING FLAG_DOMAIN NO_DOMAIN OTHER_NET_FLAG,
#     OTHER_NET_FLAG computed here from LOCALHOST_ONLY, FLAG_BIND_ADDRESS
#     and FLAG_PUBLIC_HOST); written only when there is one;
#   FOZZIE_TRUSTED_PROXY_HOPS: 2 with a domain (Caddy, then the dashboard's
#     proxy, each append an X-Forwarded-For entry), otherwise left out so
#     core-api defaults to 1;
#   FOZZIE_HSTS (ADR-0277's 2026-11-21 amendment): flag, else existing
#     (install_hsts_wanted EXISTING FLAG_HSTS FOZZIE_DOMAIN); written only
#     with a domain and only when it isn't host, the default, so a domain
#     install's .env is unchanged without --hsts and no domain drops it;
#   FOZZIE_REGISTRY_DOMAIN (ADR-0325): install_registry_domain_wanted
#     EXISTING FLAG_REGISTRY_DOMAIN NO_REGISTRY FOZZIE_DOMAIN -- none
#     without a domain, else the flag, else existing unless --no-registry;
#     written only when there is one;
#   FOZZIE_REGISTRY_HTTP_SECRET: existing (never rotated, even across
#     --no-registry and back), else the candidate only when a registry
#     domain is wanted, so an install without a registry keeps its .env
#     unchanged;
#   FOZZIE_BIND_ADDRESS, FOZZIE_PUBLIC_HOST (ADR-0277): with a domain,
#     127.0.0.1 and the domain; otherwise flag, existing (unless the
#     existing ones came from a domain this run drops), then 127.0.0.1
#     with no host (install_network_wanted EXISTING FLAG_BIND_ADDRESS
#     FLAG_PUBLIC_HOST LOCALHOST_ONLY DOMAIN); --localhost-only resets
#     both. FOZZIE_BIND_ADDRESS is always written, FOZZIE_PUBLIC_HOST only
#     when there is one;
#   FOZZIE_DASHBOARD_URL, FOZZIE_CORE_PUBLIC_URL: always derived from those,
#     the domain and the final ports (install_public_urls), never kept
#     from the existing file, so a hand edit is overwritten on the next
#     run.
# The candidates are generated by the caller, so this stays deterministic.
# Either file may be "" or missing. Returns 1, echoing why to stderr, when
# a required value is missing or a value isn't safe to write unquoted.
#   install_merge_env EXISTING IMPORT FLAG_CORE_PORT FLAG_DASHBOARD_PORT \
#     NEW_GHCR_USERNAME NEW_GHCR_TOKEN CANDIDATE_PASSWORD CANDIDATE_KEY \
#     CANDIDATE_UPDATER_TOKEN PROJECT DIR CANDIDATE_HEARTBEAT_SECRET NAME \
#     FLAG_AGENTS AGENTS_AVAILABLE FLAG_BIND_ADDRESS FLAG_PUBLIC_HOST \
#     LOCALHOST_ONLY FLAG_DOMAIN NO_DOMAIN FLAG_HSTS \
#     FLAG_REGISTRY_DOMAIN NO_REGISTRY CANDIDATE_REGISTRY_SECRET \
#     NEW_FOZRIA_USERNAME NEW_FOZRIA_TOKEN
install_merge_env() {
  local existing="$1" import="$2" flag_core="$3" flag_dash="$4"
  local new_user="$5" new_token="$6" cand_password="$7" cand_key="$8" cand_updater="$9"
  local m_COMPOSE_PROJECT="${10:-}" m_FOZZIE_INSTALL_DIR="${11:-}"
  local cand_heartbeat="${12:-}" m_FOZZIE_INSTANCE_NAME="${13:-}"
  local flag_agents="${14:-}" agents_available="${15:-false}"
  local flag_bind="${16:-}" flag_host="${17:-}" localhost_only="${18:-false}"
  local flag_domain="${19:-}" no_domain="${20:-false}" flag_hsts="${21:-}"
  local flag_registry="${22:-}" no_registry="${23:-false}" cand_registry_secret="${24:-}"
  local new_fozria_user="${25:-}" new_fozria_token="${26:-}"
  local key value line emitted=" " other_net=false
  local m_FOZZIE_VERSION="$LATEST_VERSION"
  local m_FOZZIE_CORE_API_IMAGE="$LATEST_CORE_API_IMAGE"
  local m_FOZZIE_DASHBOARD_IMAGE="$LATEST_DASHBOARD_IMAGE"
  local m_FOZZIE_UPDATER_IMAGE="$LATEST_UPDATER_IMAGE"
  local m_FOZZIE_AGENT_IMAGE="$LATEST_AGENT_IMAGE"
  local m_FOZZIE_ORCHESTRATOR_IMAGE="$LATEST_ORCHESTRATOR_IMAGE"
  local m_POSTGRES_PASSWORD m_FOZZIE_ENCRYPTION_KEY m_FOZZIE_UPDATER_TOKEN
  local m_CORE_API_PORT m_DASHBOARD_PORT m_GHCR_USERNAME m_GHCR_TOKEN
  local m_FOZZIE_ORCHESTRATOR_HEARTBEAT_SECRET m_FOZZIE_AGENTS_ENABLED m_COMPOSE_PROFILES=""
  local m_FOZZIE_BIND_ADDRESS m_FOZZIE_PUBLIC_HOST m_FOZZIE_DASHBOARD_URL m_FOZZIE_CORE_PUBLIC_URL
  local m_FOZZIE_DOMAIN m_FOZZIE_TRUSTED_PROXY_HOPS="" m_FOZZIE_HSTS
  local m_FOZZIE_REGISTRY_DOMAIN m_FOZZIE_REGISTRY_HTTP_SECRET
  local m_FOZRIA_REGISTRY_USERNAME m_FOZRIA_REGISTRY_TOKEN

  m_POSTGRES_PASSWORD="$(install_env_get "$import" POSTGRES_PASSWORD)"
  [ -n "$m_POSTGRES_PASSWORD" ] || m_POSTGRES_PASSWORD="$(install_env_get "$existing" POSTGRES_PASSWORD)"
  [ -n "$m_POSTGRES_PASSWORD" ] || m_POSTGRES_PASSWORD="$cand_password"

  m_FOZZIE_ENCRYPTION_KEY="$(install_env_get "$import" FOZZIE_ENCRYPTION_KEY)"
  [ -n "$m_FOZZIE_ENCRYPTION_KEY" ] || m_FOZZIE_ENCRYPTION_KEY="$(install_env_get "$existing" FOZZIE_ENCRYPTION_KEY)"
  [ -n "$m_FOZZIE_ENCRYPTION_KEY" ] || m_FOZZIE_ENCRYPTION_KEY="$cand_key"

  m_FOZZIE_UPDATER_TOKEN="$(install_env_get "$existing" FOZZIE_UPDATER_TOKEN)"
  [ -n "$m_FOZZIE_UPDATER_TOKEN" ] || m_FOZZIE_UPDATER_TOKEN="$cand_updater"

  m_FOZZIE_ORCHESTRATOR_HEARTBEAT_SECRET="$(install_env_get "$existing" FOZZIE_ORCHESTRATOR_HEARTBEAT_SECRET)"
  [ -n "$m_FOZZIE_ORCHESTRATOR_HEARTBEAT_SECRET" ] || m_FOZZIE_ORCHESTRATOR_HEARTBEAT_SECRET="$cand_heartbeat"

  m_FOZZIE_AGENTS_ENABLED="$(install_agents_wanted "$existing" "$flag_agents")"
  if [ "$m_FOZZIE_AGENTS_ENABLED" = true ] && [ "$agents_available" = true ]; then
    m_COMPOSE_PROFILES=agents
  fi

  if [ "$localhost_only" = true ] || [ -n "$flag_bind" ] || [ -n "$flag_host" ]; then
    other_net=true
  fi
  m_FOZZIE_DOMAIN="$(install_domain_wanted "$existing" "$flag_domain" "$no_domain" "$other_net")"
  if [ -n "$m_FOZZIE_DOMAIN" ]; then
    m_FOZZIE_TRUSTED_PROXY_HOPS=2
    m_COMPOSE_PROFILES="${m_COMPOSE_PROFILES:+$m_COMPOSE_PROFILES,}domain"
  fi
  m_FOZZIE_REGISTRY_DOMAIN="$(install_registry_domain_wanted "$existing" "$flag_registry" "$no_registry" "$m_FOZZIE_DOMAIN")"
  if [ -n "$m_FOZZIE_REGISTRY_DOMAIN" ]; then
    m_COMPOSE_PROFILES="$m_COMPOSE_PROFILES,registry"
  fi
  m_FOZZIE_REGISTRY_HTTP_SECRET="$(install_env_get "$existing" FOZZIE_REGISTRY_HTTP_SECRET)"
  if [ -z "$m_FOZZIE_REGISTRY_HTTP_SECRET" ] && [ -n "$m_FOZZIE_REGISTRY_DOMAIN" ]; then
    m_FOZZIE_REGISTRY_HTTP_SECRET="$cand_registry_secret"
  fi
  m_FOZZIE_HSTS="$(install_hsts_wanted "$existing" "$flag_hsts" "$m_FOZZIE_DOMAIN")"
  [ "$m_FOZZIE_HSTS" != host ] || m_FOZZIE_HSTS=""

  m_CORE_API_PORT="$flag_core"
  [ -n "$m_CORE_API_PORT" ] || m_CORE_API_PORT="$(install_env_get "$import" CORE_API_PORT)"
  [ -n "$m_CORE_API_PORT" ] || m_CORE_API_PORT="$(install_env_get "$existing" CORE_API_PORT)"
  [ -n "$m_CORE_API_PORT" ] || m_CORE_API_PORT=4000

  m_DASHBOARD_PORT="$flag_dash"
  [ -n "$m_DASHBOARD_PORT" ] || m_DASHBOARD_PORT="$(install_env_get "$import" DASHBOARD_PORT)"
  [ -n "$m_DASHBOARD_PORT" ] || m_DASHBOARD_PORT="$(install_env_get "$existing" DASHBOARD_PORT)"
  [ -n "$m_DASHBOARD_PORT" ] || m_DASHBOARD_PORT=5173

  read -r m_FOZZIE_BIND_ADDRESS m_FOZZIE_PUBLIC_HOST <<< "$(install_network_wanted "$existing" "$flag_bind" "$flag_host" "$localhost_only" "$m_FOZZIE_DOMAIN")"
  read -r m_FOZZIE_DASHBOARD_URL m_FOZZIE_CORE_PUBLIC_URL <<< "$(install_public_urls "$m_FOZZIE_BIND_ADDRESS" "$m_FOZZIE_PUBLIC_HOST" "$m_DASHBOARD_PORT" "$m_CORE_API_PORT" "$m_FOZZIE_DOMAIN")"

  m_GHCR_USERNAME="$new_user"
  [ -n "$m_GHCR_USERNAME" ] || m_GHCR_USERNAME="$(install_env_get "$existing" GHCR_USERNAME)"
  m_GHCR_TOKEN="$new_token"
  [ -n "$m_GHCR_TOKEN" ] || m_GHCR_TOKEN="$(install_env_get "$existing" GHCR_TOKEN)"

  m_FOZRIA_REGISTRY_USERNAME="$new_fozria_user"
  [ -n "$m_FOZRIA_REGISTRY_USERNAME" ] || m_FOZRIA_REGISTRY_USERNAME="$(install_env_get "$existing" FOZRIA_REGISTRY_USERNAME)"
  m_FOZRIA_REGISTRY_TOKEN="$new_fozria_token"
  [ -n "$m_FOZRIA_REGISTRY_TOKEN" ] || m_FOZRIA_REGISTRY_TOKEN="$(install_env_get "$existing" FOZRIA_REGISTRY_TOKEN)"

  for key in FOZZIE_VERSION FOZZIE_CORE_API_IMAGE FOZZIE_DASHBOARD_IMAGE FOZZIE_UPDATER_IMAGE POSTGRES_PASSWORD FOZZIE_ENCRYPTION_KEY FOZZIE_UPDATER_TOKEN FOZZIE_ORCHESTRATOR_HEARTBEAT_SECRET COMPOSE_PROJECT FOZZIE_INSTALL_DIR; do
    value="$(install_managed_value "$key")"
    if [ -z "$value" ]; then
      printf 'No value for %s\n' "$key" >&2
      return 1
    fi
  done
  for key in CORE_API_PORT DASHBOARD_PORT; do
    value="$(install_managed_value "$key")"
    if ! install_valid_port "$value"; then
      printf '%s "%s" is not a port number from 1 to 65535\n' "$key" "$value" >&2
      return 1
    fi
  done
  for key in $INSTALL_MANAGED_KEYS; do
    value="$(install_managed_value "$key")"
    if [ -n "$value" ] && ! [[ "$value" =~ $INSTALL_ENV_VALUE_REGEX ]]; then
      if [ "$key" = FOZZIE_INSTALL_DIR ]; then
        printf 'The install directory %s has characters the installer cannot write safely -- only letters, digits and + / = . _ : @ , - are allowed. Pick another with --dir.\n' "$value" >&2
      else
        printf '%s has characters the installer cannot write safely -- only letters, digits and + / = . _ : @ , - are allowed\n' "$key" >&2
      fi
      return 1
    fi
  done

  printf '%s\n' "$INSTALL_ENV_HEADER"
  if [ -n "$existing" ] && [ -f "$existing" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      [ "$line" != "$INSTALL_ENV_HEADER" ] || continue
      key="${line%%=*}"
      [[ "$key" =~ $INSTALL_KEY_REGEX ]] || key=""
      case " $INSTALL_MANAGED_KEYS " in
        *" $key "*)
          if [ -n "$key" ] && [ "$key" != "$line" ]; then
            case "$emitted" in
              *" $key "*) ;;
              *)
                emitted="$emitted$key "
                value="$(install_managed_value "$key")"
                [ -z "$value" ] || printf '%s=%s\n' "$key" "$value"
                ;;
            esac
            continue
          fi
          ;;
      esac
      printf '%s\n' "$line"
    done < "$existing"
  fi
  for key in $INSTALL_MANAGED_KEYS; do
    case "$emitted" in
      *" $key "*) continue ;;
    esac
    value="$(install_managed_value "$key")"
    [ -z "$value" ] || printf '%s=%s\n' "$key" "$value"
  done
  return 0
}

# Classifies `docker pull` / `docker login` / `docker info` output, given
# what was being done -- "pull" (not logged in to ghcr.io), "pull-auth"
# (pulled after a login) or "login" -- since the same words mean
# different things in each. Echoes one of: daemon, scope, login-needed,
# bad-credentials, no-access, missing-image, network, unknown.
install_docker_error_category() {
  local context="$1" out
  # Digests go first: their hex can contain "401" or "403".
  out="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]' | sed -E 's/sha256:[0-9a-f]+//g')"
  case "$out" in
    *"cannot connect to the docker daemon"* | *"is the docker daemon running"*)
      echo daemon
      return 0
      ;;
    *"does not match expected scopes"* | *"insufficient_scope"* | *"read:packages"*)
      echo scope
      return 0
      ;;
    *"unauthorized"* | *"401"* | *"authentication required"* | *"incorrect username or password"* | *"no basic auth credentials"*)
      if [ "$context" = "pull" ]; then
        echo login-needed
      else
        echo bad-credentials
      fi
      return 0
      ;;
    *"denied"* | *"403"* | *"forbidden"*)
      # Not logged in, ghcr.io can't tell who's asking: logging in is the
      # next step either way.
      if [ "$context" = "pull" ]; then
        echo login-needed
      else
        echo no-access
      fi
      return 0
      ;;
    *"manifest unknown"* | *"not found"*)
      echo missing-image
      return 0
      ;;
    *"tls"* | *"timeout"* | *"timed out"* | *"no such host"* | *"network is unreachable"*)
      echo network
      return 0
      ;;
  esac
  echo unknown
}

# A friendly message for docker output (see install_docker_error_category
# for context), naming username where it helps. Anything it doesn't
# recognise comes back as the raw output.
install_docker_error_message() {
  local context="$1" output="$2" username="${3:-}"
  case "$(install_docker_error_category "$context" "$output")" in
    daemon)
      echo "Docker isn't running. Start Docker Desktop (or the Docker service on Linux), wait for it to finish starting, then run this again."
      ;;
    scope)
      echo "That token is missing the read:packages scope. Create a new classic token with only read:packages ticked:"
      echo "  $INSTALL_PAT_URL"
      ;;
    login-needed)
      echo "Logging in to ghcr.io (GitHub's container registry) is needed to download Fozzie."
      ;;
    bad-credentials)
      echo "GitHub didn't accept that username and token: one of them is wrong, or the token has expired or been revoked."
      ;;
    no-access)
      echo "Your GitHub account hasn't been given access to the Fozzie packages yet -- ask Mark to add ${username:-your GitHub username}, accept the invites, then run this again."
      ;;
    missing-image)
      echo "This release's image is missing from the registry -- tell Mark."
      ;;
    network)
      echo "Couldn't reach ghcr.io -- this looks like a network problem. Check your internet connection (and any VPN or proxy), then run this again."
      ;;
    *)
      printf '%s\n' "$output"
      ;;
  esac
}

# Classifies `docker login` / `docker pull` output from the Fozria
# registry, registry.functionberry.com (ADR-0322, ADR-0329), given what
# was being done -- "login", "pull" (not logged in) or "pull-auth" (after
# a successful login). Echoes one of: daemon, rate-limited,
# bad-credentials, login-needed, no-access, missing-image, network,
# unknown. Unlike ghcr.io there's no token scope to get wrong: a valid
# token whose owner isn't in Release testers logs in fine and then gets
# denied (or insufficient_scope) on the pull.
install_registry_error_category() {
  local context="$1" out
  # Digests go first: their hex can contain "401", "403" or "429".
  out="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]' | sed -E 's/sha256:[0-9a-f]+//g')"
  case "$out" in
    *"cannot connect to the docker daemon"* | *"is the docker daemon running"*)
      echo daemon
      return 0
      ;;
    *"429"* | *"toomanyrequests"* | *"too many requests"* | *"too many token requests"*)
      echo rate-limited
      return 0
      ;;
  esac
  if [ "$context" = login ]; then
    case "$out" in
      *"unauthorized"* | *"401"* | *"authentication required"* | *"incorrect username or password"*)
        echo bad-credentials
        return 0
        ;;
    esac
  else
    # Checked before "not found" / "does not exist": docker's denied
    # message says "repository does not exist or may require 'docker
    # login'".
    case "$out" in
      *"unauthorized"* | *"denied"* | *"401"* | *"403"* | *"forbidden"* | *"insufficient_scope"* | *"authentication required"* | *"no basic auth credentials"*)
        if [ "$context" = pull ]; then
          echo login-needed
        else
          echo no-access
        fi
        return 0
        ;;
    esac
  fi
  case "$out" in
    *"manifest unknown"* | *"not found"* | *"does not exist"*)
      echo missing-image
      return 0
      ;;
    *"tls"* | *"timeout"* | *"timed out"* | *"no such host"* | *"network is unreachable"* | *"connection refused"* | *"dial tcp"*)
      echo network
      return 0
      ;;
  esac
  echo unknown
}

# A friendly message for the Fozria registry's docker output (see
# install_registry_error_category for context), naming the account's
# email where it helps. Anything it doesn't recognise comes back as the
# raw output.
install_registry_error_message() {
  local context="$1" output="$2" email="${3:-}"
  case "$(install_registry_error_category "$context" "$output")" in
    daemon)
      echo "Docker isn't running. Start Docker Desktop (or the Docker service on Linux), wait for it to finish starting, then run this again."
      ;;
    rate-limited)
      echo "$INSTALL_FOZRIA_APP has had too many login attempts from here. Wait a few minutes, then run this again."
      ;;
    bad-credentials)
      echo "$INSTALL_FOZRIA_APP didn't accept that email and API token: the token has expired, been revoked, or isn't an API token (your account password won't work). Make a new one on $INSTALL_FOZRIA_APP under $INSTALL_FOZRIA_TOKENS_WHERE."
      ;;
    login-needed)
      echo "Logging in to $INSTALL_FOZRIA_REGISTRY with your Fozria email and API token is needed to download Fozzie."
      ;;
    no-access)
      echo "Your Fozria account isn't in Release testers on $INSTALL_FOZRIA_APP; ask Mark to add ${email:-your email}, then run this again."
      ;;
    missing-image)
      echo "This release's image is missing from $INSTALL_FOZRIA_REGISTRY -- tell Mark."
      ;;
    network)
      echo "Couldn't reach $INSTALL_FOZRIA_REGISTRY -- this looks like a network problem. Check your internet connection (and any VPN or proxy), then run this again."
      ;;
    *)
      printf '%s\n' "$output"
      ;;
  esac
}

# Switches every LATEST_<SERVICE>_IMAGE that has a mirror to that mirror
# (ADR-0329), once the installer has pulled from the Fozria registry, so
# .env and `docker compose pull` use the refs it can actually reach. An
# empty mirror leaves its image as it is.
install_use_mirrors() {
  [ -z "$LATEST_CORE_API_MIRROR" ] || LATEST_CORE_API_IMAGE="$LATEST_CORE_API_MIRROR"
  [ -z "$LATEST_DASHBOARD_MIRROR" ] || LATEST_DASHBOARD_IMAGE="$LATEST_DASHBOARD_MIRROR"
  [ -z "$LATEST_UPDATER_MIRROR" ] || LATEST_UPDATER_IMAGE="$LATEST_UPDATER_MIRROR"
  [ -z "$LATEST_AGENT_MIRROR" ] || LATEST_AGENT_IMAGE="$LATEST_AGENT_MIRROR"
  [ -z "$LATEST_ORCHESTRATOR_MIRROR" ] || LATEST_ORCHESTRATOR_IMAGE="$LATEST_ORCHESTRATOR_MIRROR"
  return 0
}

# install_lower TEXT: TEXT in lowercase (bash 3.2 has no ${var,,}).
install_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# Classifies a database password check -- psql run over TCP against the
# instance's existing database, given its exit code and combined output.
# Echoes match (it connected), mismatch (postgres refused the password)
# or unknown (anything else: the container didn't start, a timeout, ...).
#   install_db_check_result EXIT_CODE OUTPUT
install_db_check_result() {
  case "$(install_lower "$2")" in
    *"password authentication failed"*)
      echo mismatch
      return 0
      ;;
  esac
  if [ "$1" = 0 ]; then
    echo match
  else
    echo unknown
  fi
}

# What the installer found of an instance's existing data, given whether
# its postgres volume exists (true/false), the database password this run
# would use ("" when neither .env nor --import-env has one) and
# install_db_check_result's verdict on it. Echoes one of:
#   none      no data: a fresh install;
#   ok        data, and the password opens it;
#   no-env    data, but no password for it -- the folder or .env was
#             removed after an uninstall that kept the data;
#   mismatch  data, and the password isn't the one it was created with;
#   unknown   data, and the password couldn't be checked.
#   install_data_state HAVE_DATA PASSWORD CHECK_RESULT
install_data_state() {
  if [ "$1" != true ]; then
    echo none
  elif [ -z "$2" ]; then
    echo no-env
  else
    case "$3" in
      match) echo ok ;;
      mismatch) echo mismatch ;;
      *) echo unknown ;;
    esac
  fi
}

# Classifies a failed backup's output: auth when the database refused its
# password (pg_dump's own error, or Prisma's P1000) -- the backup can't
# work and nor can core-api, so carrying on without one is no answer --
# otherwise other.
install_backup_failure_category() {
  case "$(install_lower "$1")" in
    *"password authentication failed"* | *"p1000"*) echo auth ;;
    *) echo other ;;
  esac
}

# One line on the likely cause of core-api not becoming healthy, from
# its logs, or nothing when they don't show one.
install_core_api_failure_hint() {
  case "$(install_lower "$1")" in
    *"p1000"* | *"authentication failed against database server"* | *"password authentication failed"*)
      echo "the database refused core-api's password: POSTGRES_PASSWORD in .env isn't the one this data was created with. Put back the .env this data was installed with (or re-run with --import-env pointing at it)."
      ;;
    *"invalid port number"*)
      echo "the database password breaks core-api's DATABASE_URL -- a bug in Fozzie 0.1.0's installer. If you haven't used this instance yet, reset it: 'down -v', delete POSTGRES_PASSWORD from .env, and run the installer again."
      ;;
    *"p1001"* | *"can't reach database server"*)
      echo "core-api can't reach the database: postgres isn't running or isn't healthy. Check its logs with the same command, ending in 'logs postgres'."
      ;;
  esac
  return 0
}

FOZZIE_RELEASES_URL="${FOZZIE_RELEASES_URL:-https://functionberry.github.io/fozzie-releases}"
FOZZIE_RELEASES_URL="${FOZZIE_RELEASES_URL%/}"

# Where prompts are read from and written to. Overridable only so the
# tests can make sure there's no terminal, or answer from a file.
TTY="${FOZZIE_INSTALL_TTY:-/dev/tty}"
TTY_OUT="${FOZZIE_INSTALL_TTY_OUT:-$TTY}"

# How many times (3s apart) to check for the orchestrator's first
# heartbeat. Overridable only so the tests needn't wait 90s.
ORCH_WAIT_TRIES="${FOZZIE_INSTALL_ORCH_WAIT_TRIES:-30}"

log() { printf '\n==> %s\n' "$1"; }

die() {
  printf '%s\n' "$@" >&2
  exit 1
}

# True iff there's a terminal to ask questions on. Under `curl | bash`
# stdin is the script itself, so every prompt reads the terminal instead.
have_tty() {
  (exec <"$TTY") 2>/dev/null
}

# Opens the terminal once, as fd 3, for ask and ask_secret to read from.
# Once, not per prompt: they run in $(...) subshells, which share fd 3's
# offset with this shell, so successive prompts read successive lines.
open_tty() {
  if have_tty; then
    exec 3<"$TTY"
  fi
}

# ask PROMPT: echoes the answer read from the terminal.
ask() {
  local answer
  printf '%s' "$1" >>"$TTY_OUT"
  IFS= read -r answer <&3 || answer=""
  printf '%s\n' "$answer"
}

# ask_secret PROMPT: as ask, without echoing what's typed.
ask_secret() {
  local answer
  printf '%s' "$1" >>"$TTY_OUT"
  IFS= read -rs answer <&3 || answer=""
  printf '\n' >>"$TTY_OUT"
  printf '%s\n' "$answer"
}

# confirm PROMPT: true iff the answer starts with y. Default no.
confirm() {
  case "$(ask "$1 [y/N] ")" in
    y* | Y*) return 0 ;;
    *) return 1 ;;
  esac
}

no_tty_for_login() {
  die "Logging in to ghcr.io needs your GitHub username and a token, and there's no terminal to ask on." \
    "Either run 'docker login ghcr.io' yourself first, or set GHCR_USERNAME and GHCR_TOKEN:" \
    "  curl -fsSL $FOZZIE_RELEASES_URL/install.sh | GHCR_USERNAME=you GHCR_TOKEN=ghp_... bash"
}

no_tty_for_fozria_login() {
  die "Logging in to $INSTALL_FOZRIA_REGISTRY needs your Fozria account's email and an API token, and there's no terminal to ask on." \
    "Make a token on $INSTALL_FOZRIA_APP under $INSTALL_FOZRIA_TOKENS_WHERE, then set FOZRIA_REGISTRY_USERNAME and FOZRIA_REGISTRY_TOKEN:" \
    "  curl -fsSL $FOZZIE_RELEASES_URL/install.sh | FOZRIA_REGISTRY_USERNAME=you@example.com FOZRIA_REGISTRY_TOKEN=<64-hex token> bash"
}

# docker_login HOST USER TOKEN: logs in to HOST with the token on stdin,
# never on the command line. Leaves docker's output in LOGIN_OUTPUT.
docker_login() {
  LOGIN_OUTPUT=""
  if LOGIN_OUTPUT="$(printf '%s' "$3" | docker login "$1" -u "$2" --password-stdin 2>&1)"; then
    return 0
  fi
  return 1
}

# Walks through creating a classic read:packages token and logging in
# with it, up to three tries. Sets NEW_GHCR_USERNAME / NEW_GHCR_TOKEN.
EXPLAINED_PAT=false
login_interactive() {
  local user token tries=0
  have_tty || no_tty_for_login
  if [ "$EXPLAINED_PAT" != true ]; then
    EXPLAINED_PAT=true
    echo
    echo "Fozzie's images are in GitHub's container registry (ghcr.io), which needs"
    echo "your GitHub username and a classic personal access token to download them."
    echo "Create one here -- tick ONLY read:packages, and pick an expiry you're happy with:"
    echo "  $INSTALL_PAT_URL"
    echo "The token is kept in this instance's .env so in-app updates can pull new"
    echo "images later."
    echo
  fi
  while [ "$tries" -lt 3 ]; do
    tries=$((tries + 1))
    user="$(ask "GitHub username: ")"
    if ! [[ "$user" =~ $INSTALL_GHCR_USERNAME_REGEX ]]; then
      echo "That doesn't look like a GitHub username (letters, digits and - only)."
      continue
    fi
    token="$(ask_secret "Token (input hidden): ")"
    if ! [[ "$token" =~ $INSTALL_GHCR_TOKEN_REGEX ]]; then
      echo "That doesn't look like a GitHub token (letters, digits and _ only)."
      continue
    fi
    if docker_login ghcr.io "$user" "$token"; then
      NEW_GHCR_USERNAME="$user"
      NEW_GHCR_TOKEN="$token"
      echo "Logged in to ghcr.io as $user."
      return 0
    fi
    case "$(install_docker_error_category login "$LOGIN_OUTPUT")" in
      bad-credentials | scope) install_docker_error_message login "$LOGIN_OUTPUT" "$user" ;;
      *) die "$(install_docker_error_message login "$LOGIN_OUTPUT" "$user")" ;;
    esac
  done
  die "Giving up after three tries. Check the username and token, then run this again."
}

# Walks through getting a Fozria API token and logging in to the Fozria
# registry with it (ADR-0329), up to three tries. Sets
# NEW_FOZRIA_USERNAME / NEW_FOZRIA_TOKEN.
EXPLAINED_FOZRIA=false
login_fozria_interactive() {
  local user token tries=0
  have_tty || no_tty_for_fozria_login
  if [ "$EXPLAINED_FOZRIA" != true ]; then
    EXPLAINED_FOZRIA=true
    echo
    echo "Fozzie's images are on $INSTALL_FOZRIA_REGISTRY, which needs your Fozria"
    echo "account's email and an API token to download them:"
    echo "  1. Accept your invite on https://$INSTALL_FOZRIA_APP and create your account."
    echo "  2. Make an API token there, under $INSTALL_FOZRIA_TOKENS_WHERE."
    echo "The token is kept in this instance's .env so in-app updates can pull new"
    echo "images later."
    echo
  fi
  while [ "$tries" -lt 3 ]; do
    tries=$((tries + 1))
    user="$(ask "Fozria email: ")"
    if ! [[ "$user" =~ $INSTALL_FOZRIA_USERNAME_REGEX ]]; then
      echo "That doesn't look like an email address."
      continue
    fi
    token="$(ask_secret "API token (input hidden): ")"
    if ! [[ "$token" =~ $INSTALL_FOZRIA_TOKEN_REGEX ]]; then
      echo "That doesn't look like a Fozria API token: it should be 64 characters, 0-9 and a-f."
      continue
    fi
    if docker_login "$INSTALL_FOZRIA_REGISTRY" "$user" "$token"; then
      NEW_FOZRIA_USERNAME="$user"
      NEW_FOZRIA_TOKEN="$token"
      echo "Logged in to $INSTALL_FOZRIA_REGISTRY as $user."
      return 0
    fi
    case "$(install_registry_error_category login "$LOGIN_OUTPUT")" in
      bad-credentials) install_registry_error_message login "$LOGIN_OUTPUT" "$user" ;;
      *) die "$(install_registry_error_message login "$LOGIN_OUTPUT" "$user")" ;;
    esac
  done
  die "Giving up after three tries. Check the email and API token, then run this again."
}

# registry_fall_back CONTEXT OUTPUT EMAIL: after a network or
# missing-image failure on the Fozria registry, returns 0 (so the caller
# carries on with ghcr.io) when ghcr.io can work -- GitHub credentials in
# the environment or .env, or a plain pull of the ghcr.io core-api image
# works without them. Otherwise dies with the registry's message.
registry_fall_back() {
  local context="$1" output="$2" email="$3" reason
  case "$(install_registry_error_category "$context" "$output")" in
    network) reason="it couldn't be reached" ;;
    *) reason="this release's image isn't there" ;;
  esac
  if [ "$GHCR_CREDS_KNOWN" = true ] ||
    docker pull "$LATEST_CORE_API_IMAGE" </dev/null >/dev/null 2>&1; then
    echo "Couldn't download from $INSTALL_FOZRIA_REGISTRY ($reason); trying ghcr.io instead."
    return 0
  fi
  die "$(install_registry_error_message "$context" "$output" "$email")"
}

# registry_access: logs in to the Fozria registry with the Fozria email
# and API token from the environment or .env (or, when there are none and
# a plain pull isn't enough, asks for them), then pulls the core-api
# mirror. When that worked, sets SOURCE=registry and switches every
# LATEST_*_IMAGE to its mirror; when it should fall back to ghcr.io (see
# registry_fall_back), leaves both alone; dies on anything else. Called
# as a plain statement, never in a condition, so set -e still applies.
registry_access() {
  local user="" token="" from="" context=pull category
  if [ -n "${FOZRIA_REGISTRY_USERNAME:-}" ] || [ -n "${FOZRIA_REGISTRY_TOKEN:-}" ]; then
    [[ "${FOZRIA_REGISTRY_USERNAME:-}" =~ $INSTALL_FOZRIA_USERNAME_REGEX ]] ||
      die "FOZRIA_REGISTRY_USERNAME doesn't look like an email address."
    [[ "${FOZRIA_REGISTRY_TOKEN:-}" =~ $INSTALL_FOZRIA_TOKEN_REGEX ]] ||
      die "FOZRIA_REGISTRY_TOKEN doesn't look like a Fozria API token (64 characters, 0-9 and a-f)."
    from=given
    user="$FOZRIA_REGISTRY_USERNAME"
    token="$FOZRIA_REGISTRY_TOKEN"
  elif [ -n "$SAVED_FOZRIA_USERNAME" ] && [ -n "$SAVED_FOZRIA_TOKEN" ]; then
    from=saved
    user="$SAVED_FOZRIA_USERNAME"
    token="$SAVED_FOZRIA_TOKEN"
  fi

  if [ -n "$from" ]; then
    [ "$from" != given ] || log "Logging in to $INSTALL_FOZRIA_REGISTRY as $user"
    if docker_login "$INSTALL_FOZRIA_REGISTRY" "$user" "$token"; then
      if [ "$from" = given ]; then
        NEW_FOZRIA_USERNAME="$user"
        NEW_FOZRIA_TOKEN="$token"
      fi
    else
      category="$(install_registry_error_category login "$LOGIN_OUTPUT")"
      case "$category" in
        bad-credentials)
          [ "$from" != given ] || die "$(install_registry_error_message login "$LOGIN_OUTPUT" "$user")"
          echo "The Fozria API token saved in $ENV_FILE didn't work:"
          install_registry_error_message login "$LOGIN_OUTPUT" "$user"
          login_fozria_interactive
          user="$NEW_FOZRIA_USERNAME"
          ;;
        network | missing-image)
          registry_fall_back login "$LOGIN_OUTPUT" "$user"
          return 0
          ;;
        *)
          die "$(install_registry_error_message login "$LOGIN_OUTPUT" "$user")"
          ;;
      esac
    fi
    context=pull-auth
  fi

  log "Downloading Fozzie $LATEST_VERSION from $INSTALL_FOZRIA_REGISTRY (this can take a few minutes the first time)"
  until pull_core "$LATEST_CORE_API_MIRROR"; do
    category="$(install_registry_error_category "$context" "$PULL_OUTPUT")"
    case "$category" in
      login-needed)
        login_fozria_interactive
        user="$NEW_FOZRIA_USERNAME"
        context=pull-auth
        ;;
      network | missing-image)
        registry_fall_back "$context" "$PULL_OUTPUT" "$user"
        return 0
        ;;
      *)
        die "$(install_registry_error_message "$context" "$PULL_OUTPUT" "$user")"
        ;;
    esac
  done
  SOURCE=registry
  install_use_mirrors
}

# pull_core [IMAGE]: pulls the release's core-api image (or IMAGE, its
# mirror), which also proves the login works. Leaves docker's output in
# PULL_OUTPUT.
pull_core() {
  local image="${1:-$LATEST_CORE_API_IMAGE}"
  echo "Pulling $image"
  if docker pull "$image" </dev/null >"$WORK/pull.log" 2>&1; then
    PULL_OUTPUT=""
    return 0
  fi
  PULL_OUTPUT="$(cat "$WORK/pull.log")"
  return 1
}

# pull_agent_images: pulls the agent, orchestrator and agent test
# database images. The agent image isn't a compose service, so `compose
# pull` never fetches it, and the orchestrator can't log in to ghcr.io to
# pull it itself. Leaves the failing pull's output in PULL_OUTPUT.
pull_agent_images() {
  local image
  for image in "$LATEST_AGENT_IMAGE" "$LATEST_ORCHESTRATOR_IMAGE" postgres:16; do
    echo "Pulling $image"
    if ! docker pull "$image" </dev/null >"$WORK/pull-agents.log" 2>&1; then
      PULL_OUTPUT="$(cat "$WORK/pull-agents.log")"
      return 1
    fi
  done
  PULL_OUTPUT=""
  return 0
}

# orchestrator_running: true iff this project's orchestrator container is
# running.
orchestrator_running() {
  local cid
  cid="$(dc ps -q orchestrator 2>/dev/null || true)"
  [ -n "$cid" ] && [ "$(docker inspect -f '{{.State.Running}}' "$cid" </dev/null 2>/dev/null || true)" = "true" ]
}

# db_password_check PASSWORD: sets DB_CHECK_RESULT to
# install_db_check_result's verdict on PASSWORD against this project's
# existing database (not echoed: run in this shell, the EXIT trap can
# stop its throwaway postgres). Over TCP to the
# container's own address: postgres:16 trusts every local and loopback
# connection, so only that route checks the password at all. A postgres
# already running on the data is exec'd into -- a second one on the same
# data directory could corrupt it -- otherwise a throwaway one is started
# on it, with the data's own settings (no POSTGRES_PASSWORD needed), and
# stopped again. The password reaches docker through its environment,
# never its argv.
DBCHECK_CONTAINER=""
DB_CHECK_RESULT=""
db_password_check() {
  local pw="$1" volume="${PROJECT}_fozzie_pg_local_data" cid out code=0 tries=0
  DB_CHECK_RESULT=unknown
  cid="$(docker ps -q --filter "volume=$volume" </dev/null 2>/dev/null | head -n 1 || true)"
  if [ -z "$cid" ]; then
    cid="${PROJECT}-dbcheck"
    docker rm -f "$cid" </dev/null >/dev/null 2>&1 || true
    if ! docker run -d --rm --name "$cid" -v "$volume:/var/lib/postgresql/data" postgres:16 </dev/null >"$WORK/dbcheck.log" 2>&1; then
      return 0
    fi
    DBCHECK_CONTAINER="$cid"
    until docker exec "$cid" pg_isready -q </dev/null >/dev/null 2>&1; do
      tries=$((tries + 1))
      if [ "$tries" -ge 30 ]; then
        stop_dbcheck
        return 0
      fi
      sleep 1
    done
  fi
  # shellcheck disable=SC2016 # expanded by the container's own shell
  out="$(PGPASSWORD="$pw" docker exec -e PGPASSWORD "$cid" \
    sh -c 'psql -w -h "$(hostname -i | cut -d" " -f1)" -U fozzie -d fozzie -tAc "select 1"' </dev/null 2>&1)" || code=$?
  stop_dbcheck
  DB_CHECK_RESULT="$(install_db_check_result "$code" "$out")"
}

# stop_dbcheck: stops db_password_check's throwaway postgres, if it
# started one (--rm removes it). Also run on exit.
stop_dbcheck() {
  if [ -n "$DBCHECK_CONTAINER" ]; then
    docker stop "$DBCHECK_CONTAINER" </dev/null >/dev/null 2>&1 || true
    DBCHECK_CONTAINER=""
  fi
}

# project_volumes: this Compose project's volumes, one per line. The
# label matches the project exactly, so another instance's are never
# listed.
project_volumes() {
  docker volume ls -q --filter "label=com.docker.compose.project=$PROJECT" </dev/null
}

# remove_instance_containers: removes every container (running or not)
# and network of this Compose project, leaving its volumes alone.
remove_instance_containers() {
  local ids id
  ids="$(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT" </dev/null)" ||
    die "Couldn't list $PROJECT's containers -- nothing was deleted."
  for id in $ids; do
    docker rm -f "$id" </dev/null >/dev/null || die "Couldn't remove container $id of $PROJECT."
  done
  ids="$(docker network ls -q --filter "label=com.docker.compose.project=$PROJECT" </dev/null 2>/dev/null || true)"
  for id in $ids; do
    docker network rm "$id" </dev/null >/dev/null 2>&1 || true
  done
}

# delete_instance_data: deletes this project's containers and then every
# one of its volumes -- all its data, permanently. Only ever called after
# confirm_delete.
delete_instance_data() {
  local volumes volume
  remove_instance_containers
  volumes="$(project_volumes)" || die "Couldn't list $PROJECT's volumes."
  for volume in $volumes; do
    docker volume rm "$volume" </dev/null >/dev/null || die "Couldn't delete volume $volume."
  done
  if docker volume inspect "${PROJECT}_fozzie_pg_local_data" </dev/null >/dev/null 2>&1; then
    die "${PROJECT}_fozzie_pg_local_data is still there -- delete it with:" \
      "  docker volume rm ${PROJECT}_fozzie_pg_local_data"
  fi
  echo "Deleted $PROJECT's containers and volumes."
}

# confirm_delete: lists what delete_instance_data would delete and returns
# only if the user types the project name; anything else changes nothing.
confirm_delete() {
  local volumes volume
  volumes="$(project_volumes || true)"
  echo
  echo "This permanently deletes ALL of $PROJECT's data: its database, repositories,"
  echo "attachments, agent secrets and every backup. There is no undo. Its volumes:"
  if [ -n "$volumes" ]; then
    for volume in $volumes; do
      echo "  $volume"
    done
  else
    echo "  ${PROJECT}_fozzie_pg_local_data"
  fi
  [ "$(ask "Type $PROJECT to delete it all: ")" = "$PROJECT" ] || die "Nothing changed."
}

# installer_args: the --name/--dir arguments that point the installer
# back at this instance, each with a leading space ("" for the default).
installer_args() {
  local args=""
  [ "$NAME" = local ] || args=" --name $NAME"
  if [ "$DIR" != "$(install_default_dir "$NAME" "${HOME:-}")" ]; then
    args="$args --dir $DIR"
  fi
  printf '%s\n' "$args"
}

# resolve_ipv4 HOST: the IPv4 addresses HOST resolves to, one per line,
# deduplicated -- nothing when it doesn't resolve. Uses the first lookup
# tool this machine has (getent, dig, host, then macOS's dscacheutil) and
# doesn't fall through to the next on an empty answer. Never fails.
resolve_ipv4() {
  local host="$1" out=""
  if command -v getent >/dev/null 2>&1; then
    out="$(getent ahostsv4 "$host" 2>/dev/null </dev/null | awk '{ print $1 }' || true)"
  elif command -v dig >/dev/null 2>&1; then
    out="$(dig +short A "$host" 2>/dev/null </dev/null || true)"
  elif command -v host >/dev/null 2>&1; then
    out="$(host -t A "$host" 2>/dev/null </dev/null | awk '/ has address / { print $NF }' || true)"
  elif command -v dscacheutil >/dev/null 2>&1; then
    out="$(dscacheutil -q host -a name "$host" 2>/dev/null </dev/null | awk '$1 == "ip_address:" { print $2 }' || true)"
  fi
  local line
  while IFS= read -r line; do
    line="${line%$'\r'}"
    if install_valid_ipv4 "$line"; then
      printf '%s\n' "$line"
    fi
  done <<< "$out" | sort -u || true
}

# public_ipv4: this machine's public IPv4 address, as the internet sees
# it, or nothing when it can't be found (offline, blocked, a bad answer).
# Never fails.
public_ipv4() {
  local ip
  ip="$(curl -fsS --max-time 5 https://checkip.amazonaws.com </dev/null 2>/dev/null || true)"
  ip="$(printf '%s' "$ip" | tr -d '[:space:]')"
  if install_valid_ipv4 "$ip"; then
    printf '%s\n' "$ip"
  fi
  return 0
}

# check_domain_dns DOMAIN: warns -- never fails -- when DOMAIN doesn't
# resolve yet, or resolves somewhere other than this machine. Caddy keeps
# retrying the certificate either way, so it starts working once DNS is
# right.
check_domain_dns() {
  local domain="$1" resolved public
  resolved="$(resolve_ipv4 "$domain" | tr '\n' ' ')"
  resolved="${resolved% }"
  public="$(public_ipv4)"
  case "$(install_domain_resolution_state "$resolved" "$public")" in
    none)
      echo
      echo "Warning: $domain doesn't resolve yet. Add a DNS A record pointing it at this"
      echo "machine's public address${public:+ ($public)} -- Caddy keeps retrying the certificate,"
      echo "and it'll work once DNS is right."
      ;;
    elsewhere)
      echo
      echo "Warning: $domain points at $resolved, but this machine's public address is"
      echo "$public -- Caddy keeps retrying the certificate, and it'll work once DNS is right."
      ;;
  esac
  return 0
}

# leftover_data STATE: there's data here this run can't open (STATE is
# no-env or mismatch, see install_data_state). Never makes a new password
# for it: refuses, or asks whether to keep the data or start fresh.
# Returns only once the data's been deleted, for a fresh install.
leftover_data() {
  local state="$1" args keep
  args="$(installer_args)"
  echo
  if [ "$state" = no-env ]; then
    echo "$PROJECT already has data (volume ${PROJECT}_fozzie_pg_local_data), but $ENV_FILE"
    echo "has no database password for it -- probably the folder or .env was removed after"
    echo "an uninstall that kept the data."
  else
    echo "$PROJECT already has data (volume ${PROJECT}_fozzie_pg_local_data), but the database"
    echo "password in ${IMPORT_ENV:-$ENV_FILE} isn't the one it was created with -- probably"
    echo ".env was removed or replaced after an uninstall that kept the data."
  fi
  keep="  curl -fsSL $FOZZIE_RELEASES_URL/install.sh | bash -s --$args --import-env /path/to/old/.env"
  if [ "$INSTALL_YES" = true ] || ! have_tty; then
    die "" "Nothing changed. Either:" \
      "- keep the data: copy the .env it was installed with back to $ENV_FILE and run" \
      "  this again, or point the installer at it:" "$keep" \
      "  (that .env also holds the encryption key the data and its backups need); or" \
      "- start fresh, deleting all of $PROJECT's data: run this again in a terminal," \
      "  without --yes, and pick \"start fresh\"."
  fi
  echo
  echo "  1) Keep my data: I have the old .env (it also holds the encryption key the"
  echo "     data and its backups need, so the password alone isn't enough)."
  echo "  2) Start fresh: delete all of $PROJECT's data and install a new, empty Fozzie."
  case "$(ask "Pick 1 or 2: ")" in
    1)
      die "" "Copy the .env this data was installed with back to $ENV_FILE and run" \
        "the installer again, or point it at that file:" "$keep" "Nothing changed."
      ;;
    2)
      confirm_delete
      stop_dbcheck
      delete_instance_data
      ;;
    *) die "Nothing changed." ;;
  esac
}

# uninstall: --uninstall. Asks whether to keep the data (and .env, which
# it needs) or delete everything; never guesses.
uninstall() {
  local dc_cmd="cd \"$DIR\" && docker compose -p $PROJECT --env-file .env"
  if ! have_tty; then
    die "Uninstalling asks whether to keep your data, and there's no terminal to ask on." \
      "Remove Fozzie and keep the data (and keep $ENV_FILE -- re-installing needs it):" \
      "  $dc_cmd down" \
      "Or delete everything, permanently (data, every backup, then the folder):" \
      "  $dc_cmd down -v && rm -f \"$DIR/docker-compose.yml\" \"$ENV_FILE\" \"$DIR/Caddyfile\" \"$DIR/registry-config.yml\" \"$DIR/registry-supervisor.sh\" && rmdir \"$DIR\""
  fi
  echo
  echo "Uninstalling Fozzie instance \"$NAME\" ($PROJECT):"
  echo "  1) Remove its containers and keep its data, to reinstall later."
  echo "  2) Delete everything: containers, all data and every backup, and $DIR's files."
  case "$(ask "Pick 1 or 2: ")" in
    1)
      if [ -f "$DIR/docker-compose.yml" ] && [ -f "$ENV_FILE" ]; then
        DC_FILE="$DIR/docker-compose.yml"
        DC_ENV="$ENV_FILE"
        dc down || die "'docker compose down' failed -- see the output above."
      fi
      remove_instance_containers
      echo
      echo "Removed $PROJECT's containers. Its data is still in Docker volumes."
      echo "Keep $ENV_FILE -- re-installing needs it to open this data."
      ;;
    2)
      confirm_delete
      delete_instance_data
      rm -f "$DIR/docker-compose.yml" "$ENV_FILE" "$DIR/Caddyfile" "$DIR/registry-config.yml" "$DIR/registry-supervisor.sh"
      rmdir "$DIR" 2>/dev/null || true
      echo
      echo "To finish: log Docker out of the Fozria registry (docker logout $INSTALL_FOZRIA_REGISTRY),"
      echo "and revoke the API token on $INSTALL_FOZRIA_APP ($INSTALL_FOZRIA_TOKENS_WHERE)."
      echo "If you used a GitHub token: log Docker out of GitHub's registry (docker logout ghcr.io),"
      echo "and revoke the token at https://github.com/settings/tokens."
      ;;
    *) die "Nothing changed." ;;
  esac
}

main() {
  install_parse_args "$@" || exit 1
  if [ "$INSTALL_HELP" = true ]; then
    install_usage
    exit 0
  fi

  NAME="$INSTALL_NAME"
  PROJECT="$INSTALL_PROJECT"
  DIR="$INSTALL_DIR"
  case "$DIR" in
    /*) ;;
    *) DIR="$PWD/$DIR" ;;
  esac
  ENV_FILE="$DIR/.env"
  IMPORT_ENV="$INSTALL_IMPORT_ENV"
  open_tty

  # --- 1. What's there already, and the ports -------------------------

  HAVE_EXISTING_PORTS=false
  if [ -n "$(install_env_get "$ENV_FILE" CORE_API_PORT)" ] && [ -n "$(install_env_get "$ENV_FILE" DASHBOARD_PORT)" ]; then
    HAVE_EXISTING_PORTS=true
  fi
  HAVE_IMPORT_PORTS=false
  if [ -n "$IMPORT_ENV" ]; then
    case "$IMPORT_ENV" in
      /*) ;;
      *) IMPORT_ENV="$PWD/$IMPORT_ENV" ;;
    esac
    [ -f "$IMPORT_ENV" ] || die "--import-env: no such file: $IMPORT_ENV"
    if [ -z "$(install_env_get "$IMPORT_ENV" POSTGRES_PASSWORD)" ] || [ -z "$(install_env_get "$IMPORT_ENV" FOZZIE_ENCRYPTION_KEY)" ]; then
      die "--import-env: $IMPORT_ENV needs both POSTGRES_PASSWORD and FOZZIE_ENCRYPTION_KEY."
    fi
    if [ -n "$(install_env_get "$IMPORT_ENV" CORE_API_PORT)" ] && [ -n "$(install_env_get "$IMPORT_ENV" DASHBOARD_PORT)" ]; then
      HAVE_IMPORT_PORTS=true
    fi
  fi
  # --hsts only means something at a domain: refuse it before anything
  # changes when this run ends up with none (no --domain, none remembered).
  if [ -n "$INSTALL_HSTS" ] && [ "$INSTALL_UNINSTALL" != true ] &&
    [ -z "$(install_domain_wanted "$ENV_FILE" "$INSTALL_DOMAIN" "$INSTALL_NO_DOMAIN" false)" ]; then
    die "--hsts only applies with --domain: this instance isn't served at a domain. Nothing changed."
  fi
  # The release registry's token realm is on the app's domain (ADR-0325):
  # refuse --registry-domain before anything changes when this run ends
  # up with no domain, or with the registry on the app's own one.
  if [ -n "$INSTALL_REGISTRY_DOMAIN" ] && [ "$INSTALL_UNINSTALL" != true ]; then
    local app_domain
    app_domain="$(install_domain_wanted "$ENV_FILE" "$INSTALL_DOMAIN" "$INSTALL_NO_DOMAIN" false)"
    if [ -z "$app_domain" ]; then
      die "--registry-domain needs --domain: this instance isn't served at a domain. Nothing changed."
    fi
    if [ "$INSTALL_REGISTRY_DOMAIN" = "$app_domain" ]; then
      die "--registry-domain $INSTALL_REGISTRY_DOMAIN is the app's own domain: the registry domain must differ from the app's domain. Nothing changed."
    fi
  fi
  if [ "$INSTALL_UNINSTALL" != true ] && install_needs_ports "$NAME" "$HAVE_EXISTING_PORTS" "$HAVE_IMPORT_PORTS" "$INSTALL_CORE_PORT" "$INSTALL_DASHBOARD_PORT"; then
    die "The first install of instance \"$NAME\" needs two free ports, e.g.:" \
      "  curl -fsSL $FOZZIE_RELEASES_URL/install.sh | bash -s -- --name $NAME --core-port 4001 --dashboard-port 5174"
  fi

  # --- 2. Docker, Compose and the tools this uses -----------------------

  if ! command -v docker >/dev/null 2>&1; then
    echo "Docker isn't installed (or isn't on your PATH)."
    echo "Install Docker Desktop, then run this again:"
    echo "  https://www.docker.com/products/docker-desktop/"
    exit 1
  fi

  local info
  if ! info="$(docker info </dev/null 2>&1)"; then
    if [ "$(install_docker_error_category pull "$info")" = daemon ]; then
      die "$(install_docker_error_message pull "$info")"
    fi
    die "Docker isn't running, or this user can't reach it. 'docker info' said:" "$info"
  fi

  if ! docker compose version </dev/null >/dev/null 2>&1; then
    echo "Docker is installed, but 'docker compose' (v2) isn't available."
    echo "Update Docker Desktop to a recent version, then run this again."
    exit 1
  fi

  # Older Compose rejects syntax the compose file uses, with an error that
  # doesn't say "too old" -- so say it here instead. An output format we
  # can't parse only warns: it shouldn't block an install.
  local compose_version
  compose_version="$(compose_version_from_output "$(docker compose version </dev/null 2>/dev/null || true)")"
  if [ -z "$compose_version" ]; then
    echo "Warning: couldn't tell which Docker Compose version this is -- Fozzie needs"
    echo "$FOZZIE_MIN_COMPOSE_VERSION or newer. Carrying on; if Compose errors below, update it."
  elif ! version_at_least "$compose_version" "$FOZZIE_MIN_COMPOSE_VERSION"; then
    echo "Docker Compose $compose_version is too old -- Fozzie needs $FOZZIE_MIN_COMPOSE_VERSION or newer."
    echo "Update Docker Desktop (or the compose plugin), then run this again."
    exit 1
  fi

  command -v curl >/dev/null 2>&1 || die "curl isn't installed -- install it, then run this again."
  command -v openssl >/dev/null 2>&1 || die "openssl isn't installed -- install it, then run this again."

  WORK="$(mktemp -d)"
  trap 'stop_dbcheck; rm -rf "$WORK"; rm -f "$DIR/.env.tmp" "$DIR/docker-compose.yml.tmp" "$DIR/Caddyfile.tmp" "$DIR/registry-config.yml.tmp" "$DIR/registry-supervisor.sh.tmp"' EXIT

  if [ "$INSTALL_UNINSTALL" = true ]; then
    uninstall
    exit 0
  fi

  # --- 2b. Existing data, and can this run open it? ---------------------

  # Data, not .env, is what makes this an existing instance: one installed
  # from source has its volumes under this same project, but no .env here.
  # Checked before anything's downloaded: data this run's database
  # password can't open must never get a new password generated over it
  # (it'd keep the old one, and core-api would never start).
  local have_data=false db_password data_state
  if docker volume inspect "${PROJECT}_fozzie_pg_local_data" </dev/null >/dev/null 2>&1; then
    have_data=true
  fi
  db_password="$(install_env_get "$IMPORT_ENV" POSTGRES_PASSWORD)"
  [ -n "$db_password" ] || db_password="$(install_env_get "$ENV_FILE" POSTGRES_PASSWORD)"
  # Unchecked, data with a password is "unknown": then check it.
  data_state="$(install_data_state "$have_data" "$db_password" "")"
  if [ "$data_state" = unknown ]; then
    log "Checking the database password against $PROJECT's existing data"
    db_password_check "$db_password"
    data_state="$(install_data_state "$have_data" "$db_password" "$DB_CHECK_RESULT")"
  fi
  case "$data_state" in
    no-env | mismatch)
      leftover_data "$data_state"
      have_data=false
      ;;
    unknown)
      echo "Warning: couldn't check the database password against $PROJECT's data -- carrying on."
      ;;
  esac

  # --- 3. The latest release -------------------------------------------

  log "Checking the latest Fozzie release"
  if ! curl -fsSL "$FOZZIE_RELEASES_URL/latest.env" -o "$WORK/latest.env" </dev/null; then
    die "Couldn't download $FOZZIE_RELEASES_URL/latest.env -- check your internet connection, then run this again."
  fi
  if ! install_parse_latest_env "$WORK/latest.env" 2>"$WORK/latest.err"; then
    die "The release metadata looks wrong ($(cat "$WORK/latest.err")) -- don't continue, tell Mark."
  fi
  echo "Latest release: $LATEST_VERSION"

  # --- 4. Registry access ----------------------------------------------

  # The release's images are on ghcr.io and, when latest.env lists
  # mirrors, also on registry.functionberry.com (ADR-0329). SOURCE is where
  # this run downloads them from: the registry when it has them and this
  # install has (or is a new install that can be given) a Fozria API
  # token; otherwise ghcr.io, as before. An install with only a GitHub
  # token stays on ghcr.io until the Fozria rename's phase 2 moves it.
  NEW_GHCR_USERNAME=""
  NEW_GHCR_TOKEN=""
  NEW_FOZRIA_USERNAME=""
  NEW_FOZRIA_TOKEN=""
  SOURCE=ghcr
  local logged_in=false existing_user existing_token
  existing_user="$(install_env_get "$ENV_FILE" GHCR_USERNAME)"
  existing_token="$(install_env_get "$ENV_FILE" GHCR_TOKEN)"
  SAVED_FOZRIA_USERNAME="$(install_env_get "$ENV_FILE" FOZRIA_REGISTRY_USERNAME)"
  SAVED_FOZRIA_TOKEN="$(install_env_get "$ENV_FILE" FOZRIA_REGISTRY_TOKEN)"
  GHCR_CREDS_KNOWN=false
  if [ -n "${GHCR_USERNAME:-}" ] || [ -n "${GHCR_TOKEN:-}" ] ||
    { [ -n "$existing_user" ] && [ -n "$existing_token" ]; }; then
    GHCR_CREDS_KNOWN=true
  fi

  if [ -n "$LATEST_CORE_API_MIRROR" ]; then
    if [ -z "${FOZRIA_REGISTRY_USERNAME:-}" ] && [ -z "${FOZRIA_REGISTRY_TOKEN:-}" ] &&
      { [ -z "$SAVED_FOZRIA_USERNAME" ] || [ -z "$SAVED_FOZRIA_TOKEN" ]; } &&
      [ "$GHCR_CREDS_KNOWN" = true ]; then
      echo "Note: this release is also on $INSTALL_FOZRIA_REGISTRY; switching to a Fozria account comes with a later update. Carrying on with ghcr.io."
    else
      registry_access
    fi
  fi

  if [ "$SOURCE" = ghcr ]; then
    if [ -n "${GHCR_USERNAME:-}" ] || [ -n "${GHCR_TOKEN:-}" ]; then
      [[ "${GHCR_USERNAME:-}" =~ $INSTALL_GHCR_USERNAME_REGEX ]] ||
        die "GHCR_USERNAME doesn't look like a GitHub username (letters, digits and - only)."
      [[ "${GHCR_TOKEN:-}" =~ $INSTALL_GHCR_TOKEN_REGEX ]] ||
        die "GHCR_TOKEN doesn't look like a GitHub token (letters, digits and _ only)."
      log "Logging in to ghcr.io as $GHCR_USERNAME"
      docker_login ghcr.io "$GHCR_USERNAME" "$GHCR_TOKEN" ||
        die "$(install_docker_error_message login "$LOGIN_OUTPUT" "$GHCR_USERNAME")"
      NEW_GHCR_USERNAME="$GHCR_USERNAME"
      NEW_GHCR_TOKEN="$GHCR_TOKEN"
      logged_in=true
    elif [ -n "$existing_user" ] && [ -n "$existing_token" ]; then
      if docker_login ghcr.io "$existing_user" "$existing_token"; then
        logged_in=true
      else
        echo "The GitHub token saved in $ENV_FILE didn't work:"
        install_docker_error_message login "$LOGIN_OUTPUT" "$existing_user"
      fi
    fi

    log "Downloading Fozzie $LATEST_VERSION (this can take a few minutes the first time)"
    local context=pull category user_for_messages tries=0
    if [ "$logged_in" = true ]; then
      context=pull-auth
    fi
    until pull_core; do
      user_for_messages="${NEW_GHCR_USERNAME:-$existing_user}"
      category="$(install_docker_error_category "$context" "$PULL_OUTPUT")"
      case "$category" in
        login-needed | bad-credentials | scope)
          tries=$((tries + 1))
          [ "$tries" -le 3 ] || die "$(install_docker_error_message "$context" "$PULL_OUTPUT" "$user_for_messages")"
          if [ "$category" != login-needed ]; then
            install_docker_error_message "$context" "$PULL_OUTPUT" "$user_for_messages"
          fi
          login_interactive
          context=pull-auth
          ;;
        *)
          die "$(install_docker_error_message "$context" "$PULL_OUTPUT" "$user_for_messages")"
          ;;
      esac
    done
  fi

  if [ "$SOURCE" = registry ]; then
    # The pull worked without a token being given or saved -- an existing
    # `docker login registry.functionberry.com`, say. One-click updates
    # pull from inside a container, so they need the token in .env.
    if [ -z "$NEW_FOZRIA_TOKEN" ] && [ -z "$SAVED_FOZRIA_TOKEN" ]; then
      if [ "$INSTALL_YES" != true ] && have_tty; then
        echo
        echo "One-click updates need your Fozria email and an API token saved in"
        echo "$ENV_FILE. You can skip this and re-run the installer later."
        if confirm "Enter them now?"; then
          login_fozria_interactive
        fi
      else
        echo "Note: no Fozria API token saved -- one-click updates will need one. Re-run the installer to add it."
      fi
    fi
  else
    # The pull worked without asking -- an existing `docker login`, say.
    # One-click updates pull from inside a container, which can't read
    # Docker Desktop's credential store, so they need the token in .env.
    if [ -z "$NEW_GHCR_TOKEN" ] && [ -z "$existing_token" ]; then
      if [ "$INSTALL_YES" != true ] && have_tty; then
        echo
        echo "One-click updates need your GitHub username and a read:packages token saved"
        echo "in $ENV_FILE. You can skip this and re-run the installer later."
        if confirm "Enter them now?"; then
          login_interactive
        fi
      else
        echo "Note: no GitHub token saved -- one-click updates will need one. Re-run the installer to add it."
      fi
    fi
  fi

  # --- 4b. The agent service's images ---------------------------------

  # Decided before .env is merged, from the flag and the existing .env, so
  # a failed pull can turn agents off for this run (AGENTS_AVAILABLE) while
  # the remembered choice stays as it was.
  AGENTS_WANTED="$(install_agents_wanted "$ENV_FILE" "$INSTALL_AGENTS")"
  AGENTS_AVAILABLE=false
  AGENTS_SKIPPED=""
  if [ "$AGENTS_WANTED" = true ]; then
    if [ -z "$LATEST_AGENT_IMAGE" ] || [ -z "$LATEST_ORCHESTRATOR_IMAGE" ]; then
      AGENTS_SKIPPED=release
      echo "This release doesn't include the agent service -- agents are off for now."
    else
      log "Downloading the agent service"
      if pull_agent_images; then
        AGENTS_AVAILABLE=true
      else
        AGENTS_SKIPPED=pull
        echo
        echo "Warning: couldn't download the agent service, so agents are off for now:"
        if [ "$SOURCE" = registry ]; then
          install_registry_error_message pull-auth "$PULL_OUTPUT" "${NEW_FOZRIA_USERNAME:-$SAVED_FOZRIA_USERNAME}"
          echo "Re-run this installer once that's sorted. Carrying on without agents."
        else
          install_docker_error_message pull-auth "$PULL_OUTPUT" "${NEW_GHCR_USERNAME:-$existing_user}"
          echo "If you haven't yet, accept the fozzie-dist-agent and fozzie-dist-orchestrator"
          echo "invites, then re-run this installer. Carrying on without agents."
        fi
      fi
    fi
  fi

  # --- 5. Existing data? -----------------------------------------------

  local old_version
  old_version="$(install_env_get "$ENV_FILE" FOZZIE_VERSION)"

  if [ "$have_data" = true ] && [ "$INSTALL_YES" != true ]; then
    have_tty || die "$PROJECT already has data, and there's no terminal to confirm on -- re-run with --yes."
    echo
    echo "This will replace the running containers of $PROJECT with the published"
    echo "Fozzie $LATEST_VERSION images; your data stays."
    confirm "Continue?" || die "Nothing changed."
  fi

  # --- 5b. Network access (ADR-0277) -------------------------------------

  # Opt-in: only the dashboard's port, and only with --public-host or
  # --bind-address (remembered in .env after that). Warn whenever this run
  # turns it on or changes where it listens; a re-run that keeps the same
  # setting says nothing. --domain is the exception: Caddy alone listens
  # publicly, on 80 and 443, over HTTPS, and the dashboard stays on
  # loopback -- so it gets its own notice, not the plain-HTTP warning.
  local NET_BIND NET_HOST prev_bind prev_host DOMAIN prev_domain other_net=false
  if [ "$INSTALL_LOCALHOST_ONLY" = true ] || [ -n "$INSTALL_BIND_ADDRESS" ] || [ -n "$INSTALL_PUBLIC_HOST" ]; then
    other_net=true
  fi
  DOMAIN="$(install_domain_wanted "$ENV_FILE" "$INSTALL_DOMAIN" "$INSTALL_NO_DOMAIN" "$other_net")"
  prev_domain="$(install_lower "$(install_env_get "$ENV_FILE" FOZZIE_DOMAIN)")"
  read -r NET_BIND NET_HOST <<< "$(install_network_wanted "$ENV_FILE" "$INSTALL_BIND_ADDRESS" "$INSTALL_PUBLIC_HOST" "$INSTALL_LOCALHOST_ONLY" "$DOMAIN")"
  prev_bind="$(install_env_get "$ENV_FILE" FOZZIE_BIND_ADDRESS)"
  [ -n "$prev_bind" ] || prev_bind=127.0.0.1
  prev_host="$(install_env_get "$ENV_FILE" FOZZIE_PUBLIC_HOST)"
  if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "$prev_domain" ]; then
    echo
    install_domain_notice
    if [ "$INSTALL_YES" != true ] && have_tty; then
      confirm "Serve Fozzie at https://$DOMAIN on ports 80 and 443?" || die "Nothing changed."
    fi
  elif ! install_is_loopback "$NET_BIND" &&
    { install_is_loopback "$prev_bind" || [ "$NET_BIND" != "$prev_bind" ] || [ "$NET_HOST" != "$prev_host" ]; }; then
    echo
    install_network_warning
    if [ "$INSTALL_YES" != true ] && have_tty; then
      confirm "Open Fozzie's dashboard to your network?" || die "Nothing changed."
    fi
  fi
  # HSTS preload can't be taken back quickly: say so once, when it's new.
  if [ -n "$DOMAIN" ] &&
    [ "$(install_hsts_wanted "$ENV_FILE" "$INSTALL_HSTS" "$DOMAIN")" = preload ] &&
    [ "$(install_env_get "$ENV_FILE" FOZZIE_HSTS)" != preload ]; then
    echo
    echo "Warning: --hsts preload commits every subdomain of the registered domain to HTTPS, in every browser, and is very slow to undo."
  fi
  # The release registry (ADR-0325): a second site on the same Caddy, so
  # it only exists with a domain. Its own notice whenever it's new or
  # changes; a re-run that keeps it says nothing.
  local REGISTRY_DOMAIN prev_registry
  REGISTRY_DOMAIN="$(install_registry_domain_wanted "$ENV_FILE" "$INSTALL_REGISTRY_DOMAIN" "$INSTALL_NO_REGISTRY" "$DOMAIN")"
  prev_registry="$(install_lower "$(install_env_get "$ENV_FILE" FOZZIE_REGISTRY_DOMAIN)")"
  if [ -n "$REGISTRY_DOMAIN" ] && [ "$REGISTRY_DOMAIN" != "$prev_registry" ]; then
    echo
    install_registry_notice "$REGISTRY_DOMAIN"
    if [ "$INSTALL_YES" != true ] && have_tty; then
      confirm "Serve a release registry at https://$REGISTRY_DOMAIN?" || die "Nothing changed."
    fi
  fi
  # Warns only: DNS can be added after the install, and Caddy retries.
  if [ -n "$DOMAIN" ]; then
    check_domain_dns "$DOMAIN"
  fi
  if [ -n "$REGISTRY_DOMAIN" ]; then
    check_domain_dns "$REGISTRY_DOMAIN"
  fi

  # --- 6. docker-compose.yml and .env -----------------------------------

  # Written beside the real files and moved into place only once the
  # backup below has worked, so an abort leaves the old install as it was
  # (and the next run still sees the old version, and backs up again).
  mkdir -p "$DIR"
  DIR="$(cd "$DIR" && pwd)"
  ENV_FILE="$DIR/.env"
  if ! curl -fsSL "$FOZZIE_RELEASES_URL/docker-compose.yml" -o "$DIR/docker-compose.yml.tmp" </dev/null; then
    die "Couldn't download $FOZZIE_RELEASES_URL/docker-compose.yml -- check your internet connection, then run this again."
  fi

  local merged
  merged="$(install_merge_env "$ENV_FILE" "$IMPORT_ENV" "$INSTALL_CORE_PORT" "$INSTALL_DASHBOARD_PORT" \
    "$NEW_GHCR_USERNAME" "$NEW_GHCR_TOKEN" \
    "$(openssl rand -hex 24)" "$(openssl rand -base64 32)" "$(openssl rand -hex 32)" \
    "$PROJECT" "$DIR" "$(openssl rand -hex 32)" "$NAME" "$INSTALL_AGENTS" "$AGENTS_AVAILABLE" \
    "$INSTALL_BIND_ADDRESS" "$INSTALL_PUBLIC_HOST" "$INSTALL_LOCALHOST_ONLY" \
    "$INSTALL_DOMAIN" "$INSTALL_NO_DOMAIN" "$INSTALL_HSTS" \
    "$INSTALL_REGISTRY_DOMAIN" "$INSTALL_NO_REGISTRY" "$(openssl rand -hex 32)" \
    "$NEW_FOZRIA_USERNAME" "$NEW_FOZRIA_TOKEN")" ||
    die "Couldn't write $ENV_FILE."
  # Hex for new installs (see install_url_safe_password); this catches one
  # made by 0.1.0's installer, whose password can never work. Its database
  # was created with that password, so it can't just be swapped here.
  local db_password
  db_password="$(printf '%s\n' "$merged" | sed -n 's/^POSTGRES_PASSWORD=//p' | tail -n 1)"
  if ! install_url_safe_password "$db_password"; then
    die "This instance's database password (POSTGRES_PASSWORD in $ENV_FILE) has characters" \
      "that break the database connection -- a bug in Fozzie 0.1.0's installer, so core-api" \
      "has never been able to start. If you haven't used this instance yet, reset it:" \
      "  cd \"$DIR\" && docker compose -p $PROJECT --env-file .env down -v" \
      "then delete the POSTGRES_PASSWORD line from $ENV_FILE and run this installer again."
  fi
  (
    umask 077
    printf '%s\n' "$merged" >"$DIR/.env.tmp"
  )
  chmod 600 "$DIR/.env.tmp"
  CORE_API_PORT="$(install_env_get "$DIR/.env.tmp" CORE_API_PORT)"
  DASHBOARD_PORT="$(install_env_get "$DIR/.env.tmp" DASHBOARD_PORT)"
  # Lowercase locals, not the .env keys' own names: a variable exported
  # under one of those would reach docker compose and override .env.
  local public_dashboard_url bind_address
  public_dashboard_url="$(install_env_get "$DIR/.env.tmp" FOZZIE_DASHBOARD_URL)"
  bind_address="$(install_env_get "$DIR/.env.tmp" FOZZIE_BIND_ADDRESS)"
  # The caddy service's config, with a domain (ADR-0277's 2026-11-21
  # amendment): generated here, since only docker-compose.yml is
  # downloaded, and rewritten on every run. With a release registry
  # (ADR-0325), the Caddyfile gets its second site, and the registry's
  # config and supervisor are generated beside it.
  local registry_domain
  registry_domain="$(install_env_get "$DIR/.env.tmp" FOZZIE_REGISTRY_DOMAIN)"
  if [ -n "$DOMAIN" ]; then
    install_caddyfile "$DOMAIN" "$(install_env_get "$DIR/.env.tmp" FOZZIE_HSTS)" "$registry_domain" >"$DIR/Caddyfile.tmp" ||
      die "Couldn't write $DIR/Caddyfile."
  fi
  if [ -n "$registry_domain" ]; then
    install_registry_config "$registry_domain" "$DOMAIN" >"$DIR/registry-config.yml.tmp" ||
      die "Couldn't write $DIR/registry-config.yml."
    install_registry_supervisor >"$DIR/registry-supervisor.sh.tmp" ||
      die "Couldn't write $DIR/registry-supervisor.sh."
  fi

  DC_FILE="$DIR/docker-compose.yml.tmp"
  DC_ENV="$DIR/.env.tmp"

  # --- 7. Back up before changing versions -----------------------------

  if [ "$have_data" = true ] && [ "$old_version" != "$LATEST_VERSION" ]; then
    log "Pulling the rest of Fozzie $LATEST_VERSION"
    dc pull || die "Couldn't pull the images -- nothing changed. Check the output above, then run this again."
    log "Taking a backup before switching to $LATEST_VERSION"
    if ! dc run --rm -T backup node dist/backupCli.js run 2>&1 | tee "$WORK/backup.log"; then
      # The database refusing the password isn't a backup problem: core-api
      # would be refused too, so carrying on can only end in a timeout.
      if [ "$(install_backup_failure_category "$(cat "$WORK/backup.log")")" = auth ]; then
        die "" "The backup failed because the database refused its password: POSTGRES_PASSWORD" \
          "in ${IMPORT_ENV:-$ENV_FILE} isn't the one $PROJECT's data was created with." \
          "Put back the .env this data was installed with, or re-run with" \
          "--import-env pointing at it. Nothing changed."
      fi
      echo "The backup failed -- see the output above."
      if [ "$INSTALL_YES" = true ] || ! have_tty || ! confirm "Continue WITHOUT a backup?"; then
        die "Nothing changed."
      fi
    fi
  fi

  mv "$DIR/docker-compose.yml.tmp" "$DIR/docker-compose.yml"
  mv "$DIR/.env.tmp" "$ENV_FILE"
  # A changed Caddyfile needs caddy recreated (below): its single-file bind
  # mount stays on the old file, and `up -d` doesn't see the change.
  local caddyfile_changed=false
  if [ -f "$DIR/Caddyfile.tmp" ]; then
    if [ -f "$DIR/Caddyfile" ] && ! cmp -s "$DIR/Caddyfile.tmp" "$DIR/Caddyfile"; then
      caddyfile_changed=true
    fi
    mv "$DIR/Caddyfile.tmp" "$DIR/Caddyfile"
  fi
  # Likewise the registry's files: single-file binds, so a change needs
  # the registry recreated.
  local registry_files_changed=false registry_file
  for registry_file in registry-config.yml registry-supervisor.sh; do
    if [ -f "$DIR/$registry_file.tmp" ]; then
      if [ -f "$DIR/$registry_file" ] && ! cmp -s "$DIR/$registry_file.tmp" "$DIR/$registry_file"; then
        registry_files_changed=true
      fi
      mv "$DIR/$registry_file.tmp" "$DIR/$registry_file"
    fi
  done
  DC_FILE="$DIR/docker-compose.yml"
  DC_ENV="$ENV_FILE"

  # --- 8. Start ----------------------------------------------------------

  local dc_cmd
  dc_cmd="cd \"$DIR\" && docker compose -p $PROJECT --env-file .env"
  local profiles
  profiles="$(install_env_get "$ENV_FILE" COMPOSE_PROFILES)"

  log "Starting Fozzie instance \"$NAME\""
  # COMPOSE_PROFILES in .env decides whether this starts the orchestrator
  # ("agents"), Caddy ("domain") and the release registry ("registry").
  if ! dc up -d; then
    case ",$profiles," in
      *,domain,*)
        die "" "Couldn't start Fozzie -- see the output above. Serving https://$DOMAIN needs ports" \
          "80 and 443 on this machine: they may already be in use (another web server, or" \
          "another instance serving a domain here). Caddy's logs:" \
          "  $dc_cmd logs caddy"
        ;;
    esac
    die "" "Couldn't start Fozzie -- see the output above."
  fi
  case ",$profiles," in
    *,domain,*)
      # A first Caddyfile, or one alongside a changed caddy service, is
      # already in the container `up -d` (re)created; an unchanged one
      # needs nothing.
      if [ "$caddyfile_changed" = true ]; then
        dc up -d --no-deps --force-recreate caddy ||
          die "" "Couldn't restart Caddy with its new configuration -- see the output above. Caddy's logs:" \
            "  $dc_cmd logs caddy"
      fi
      ;;
    *)
      # `up -d` with the profile off leaves a Caddy that's already running
      # alone (--no-domain), still holding ports 80 and 443, so remove it,
      # and the Caddyfile it ran. Its volumes stay, so turning the domain
      # back on reuses the certificates. A no-op when there isn't one.
      dc --profile domain rm -sf caddy >/dev/null 2>&1 || true
      rm -f "$DIR/Caddyfile"
      ;;
  esac
  case ",$profiles," in
    *,registry,*)
      if [ "$registry_files_changed" = true ]; then
        dc up -d --no-deps --force-recreate registry ||
          die "" "Couldn't restart the release registry with its new configuration -- see the output above. Its logs:" \
            "  $dc_cmd logs registry"
      fi
      ;;
    *)
      # Likewise a release registry left running alone (--no-registry, or
      # --no-domain, which drops it too) is removed, with its two files.
      # Its volume stays, so turning it back on finds the stored images.
      # A no-op when there isn't one.
      dc --profile registry rm -sf registry >/dev/null 2>&1 || true
      rm -f "$DIR/registry-config.yml" "$DIR/registry-supervisor.sh"
      ;;
  esac
  local agents_on=false
  case ",$profiles," in
    *,agents,*) agents_on=true ;;
  esac
  if [ "$agents_on" != true ]; then
    # `up -d` with the profile off leaves an orchestrator that's already
    # running alone, so stop it. `stop`, not `rm`: with restart:
    # unless-stopped a stopped container stays stopped across Docker
    # restarts. Agent containers already running finish their task. A
    # no-op when there isn't one.
    dc --profile agents stop orchestrator >/dev/null 2>&1 || true
  fi

  # --- 9. Wait for core-api ---------------------------------------------

  log "Waiting for core-api to be ready (the first start runs database migrations)"
  local ready=false
  for _ in $(seq 1 90); do
    if curl -sf "http://127.0.0.1:$CORE_API_PORT/health" </dev/null >/dev/null 2>&1; then
      ready=true
      break
    fi
    sleep 2
  done
  if [ "$ready" != true ]; then
    local hint
    hint="$(install_core_api_failure_hint "$(dc logs --no-color --tail 200 core-api 2>&1 || true)")"
    if [ -n "$hint" ]; then
      die "core-api didn't become healthy within 3 minutes." \
        "Likely cause: $hint" \
        "Its logs:" \
        "  cd \"$DIR\" && docker compose -p $PROJECT --env-file .env logs core-api"
    fi
    die "core-api didn't become healthy within 3 minutes. Check its logs for what went wrong:" \
      "  cd \"$DIR\" && docker compose -p $PROJECT --env-file .env logs core-api"
  fi

  # --- 9b. Agents on: wait for the orchestrator's first heartbeat ------

  if [ "$agents_on" = true ]; then
    log "Waiting for the agent service to report to Fozzie"
    # The orchestrator started in the same `up -d` as core-api, so its
    # first heartbeats can fail while core-api migrates: a failing state
    # isn't final here, unlike ./install.sh's wait. It keeps retrying, and
    # logs "is getting through again" once one does.
    local orch_state=pending orch_logs="" tries=0 code
    while :; do
      tries=$((tries + 1))
      orch_logs="$(dc logs --no-color orchestrator 2>&1 || true)"
      orch_state="$(orchestrator_wait_state "$orch_logs")"
      case "$orch_state" in
        ok | refused | off) break ;;
      esac
      [ "$tries" -lt "$ORCH_WAIT_TRIES" ] || break
      sleep 3
    done
    case "$orch_state" in
      ok)
        echo "Agents are on: the orchestrator is running and reporting to Fozzie."
        ;;
      *)
        case "$orch_state" in
          failing)
            code="$(orchestrator_heartbeat_failure_code "$orch_logs")"
            echo "Warning: the orchestrator's heartbeat to core-api is failing (HTTP ${code:-?}),"
            echo "so Fozzie shows the agent service as not running."
            case "$code" in
              404) echo "core-api didn't get FOZZIE_ORCHESTRATOR_HEARTBEAT_SECRET -- re-run the installer to recreate it." ;;
              401) echo "The orchestrator's and core-api's heartbeat secrets differ -- re-run the installer to recreate both." ;;
              000 | none) echo "The orchestrator can't reach core-api at all." ;;
            esac
            ;;
          off)
            echo "Warning: the orchestrator started with heartbeats off, so Fozzie can't show it as running."
            ;;
          pending)
            echo "Warning: the orchestrator hasn't reported to core-api yet (waited $((ORCH_WAIT_TRIES * 3))s)."
            ;;
          *)
            echo "Warning: the orchestrator didn't start properly."
            ;;
        esac
        echo "Check its logs:"
        echo "  $dc_cmd logs orchestrator"
        # core-api is up, so a slow or failing heartbeat isn't a failed
        # install -- only an orchestrator that isn't running is.
        if ! orchestrator_running; then
          die "The orchestrator container isn't running."
        fi
        ;;
    esac
  fi

  # --- 10. Fresh install only: hand the setup token to the browser -----

  # With a domain, the browser goes through Caddy: localhost:<port> is the
  # server's own loopback, and on a headless server there's no browser
  # here anyway, so the URL is printed below.
  local base_url="http://localhost:$DASHBOARD_PORT"
  [ -z "$DOMAIN" ] || base_url="https://$DOMAIN"
  local url="$base_url"
  if [ "$have_data" != true ]; then
    # The one-time block core-api prints on its very first boot (ADR-0019),
    # read the same way the source install reads it.
    local token
    token="$(dc logs core-api 2>/dev/null |
      grep -A1 "First-run bootstrap admin credential" |
      tail -n1 |
      sed -E 's/^[^|]*\| ?//' || true)"
    if [ -z "$token" ]; then
      echo "Couldn't find the one-time setup token in core-api's logs. Look for it with:"
      echo "  cd \"$DIR\" && docker compose -p $PROJECT --env-file .env logs core-api"
    else
      url="$base_url/?setup_token=$token"
    fi
  fi

  # --- 11. Open the browser, and how to run it from here -----------------

  local update_args
  update_args="$(installer_args)"

  log "Fozzie $LATEST_VERSION (instance \"$NAME\") is running at $base_url"
  if [ -n "$DOMAIN" ]; then
    echo "Served over HTTPS by Caddy on ports 80 and 443. The first visit can take a few"
    echo "seconds while the certificate is issued. If the page doesn't load, check DNS,"
    echo "the firewalls, and Caddy's logs:"
    echo "  $dc_cmd logs caddy"
    echo "Stop serving at $DOMAIN (back to this machine only):"
    echo "  curl -fsSL $FOZZIE_RELEASES_URL/install.sh | bash -s --$update_args --no-domain"
  fi
  if [ -n "$REGISTRY_DOMAIN" ]; then
    echo "Release registry: https://$REGISTRY_DOMAIN -- it serves nothing until an admin enables"
    echo "the release registry in Fozria (see \"Serve releases from this server\" in"
    echo "docs/DEPLOY_TO_A_SERVER.md). Its logs:"
    echo "  $dc_cmd logs registry"
    echo "Remove the registry (its stored images stay in their volume):"
    echo "  curl -fsSL $FOZZIE_RELEASES_URL/install.sh | bash -s --$update_args --no-registry"
  fi
  if [ -n "$bind_address" ] && ! install_is_loopback "$bind_address"; then
    case "$public_dashboard_url" in
      "" | http://localhost:*)
        echo "From other devices: http://$(hostname 2>/dev/null || echo "<this machine's name or IP>"):$DASHBOARD_PORT (add --public-host so emailed links use it)"
        ;;
      *)
        echo "From other devices: $public_dashboard_url"
        ;;
    esac
    echo "Plain HTTP, open to your network. Back to this machine only:"
    echo "  curl -fsSL $FOZZIE_RELEASES_URL/install.sh | bash -s --$update_args --localhost-only"
  fi
  echo
  if [ -n "$update_args" ]; then
    echo "Update:        curl -fsSL $FOZZIE_RELEASES_URL/install.sh | bash -s --$update_args"
  else
    echo "Update:        curl -fsSL $FOZZIE_RELEASES_URL/install.sh | bash"
  fi
  echo "Stop:          $dc_cmd stop"
  echo "Start again:   $dc_cmd up -d"
  echo "List backups:  $dc_cmd run --rm backup node dist/backupCli.js list"
  echo "Uninstall:     $dc_cmd down     (keeps your data -- keep .env too: it's needed to open it)"
  echo "               $dc_cmd down -v  (DELETES ALL DATA, permanently)"
  echo "               or re-run the installer with --uninstall, which asks which"
  echo
  if [ "$agents_on" = true ]; then
    echo "Agents are on: create one in Agents → Set up an agent"
    echo "Turn agents off:  curl -fsSL $FOZZIE_RELEASES_URL/install.sh | bash -s --$update_args --no-agents"
  elif [ "$AGENTS_SKIPPED" = release ]; then
    echo "Agents are off: this release doesn't include the agent service yet."
  elif [ "$AGENTS_SKIPPED" = pull ]; then
    echo "Agents are off for now: the agent service couldn't be downloaded (see above)."
    echo "Re-run the installer once that's sorted out."
  else
    echo "Agents are off. Turn them on:  curl -fsSL $FOZZIE_RELEASES_URL/install.sh | bash -s --$update_args --with-agents"
  fi
  echo

  if command -v open >/dev/null 2>&1; then
    open "$url"
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$url" >/dev/null 2>&1 || true
  else
    echo "Open this URL in your browser:"
    echo "  $url"
  fi
}

# Every docker compose call, against this instance's own project and files.
# stdin is /dev/null: under `curl | bash` it's the rest of this script.
dc() {
  docker compose -p "$PROJECT" -f "$DC_FILE" --env-file "$DC_ENV" "$@" </dev/null
}

# Last, so `curl | bash` has read the whole script before any of it runs.
main "$@"
