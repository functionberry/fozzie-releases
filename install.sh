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
# Switching an instance installed from source to these images, keeping
# its data: --import-env <its env file> takes its secrets and ports.
# `--help` lists every option.
#
# What this does, in order: checks Docker and Compose; reads the latest
# release's image refs from latest.env; logs in to ghcr.io if the images
# need it (walking you through creating a read:packages token); writes
# docker-compose.yml and .env (chmod 600, secrets generated once and kept)
# into ~/fozzie or ~/fozzie-<name>; takes a backup first when it's
# replacing an existing version; starts everything, waits for core-api to
# be healthy and opens your browser -- on a fresh install, with the
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

# Every value the installer writes into .env is from this set, so it's
# written unquoted and reads back the same to Compose and to
# install_env_get alike (base64 secrets, digest refs, ports, versions).
INSTALL_ENV_VALUE_REGEX="^[${INSTALL_UPPER}${INSTALL_LOWER}${INSTALL_DIGITS}+/=._:@-]+\$"

# The keys install_merge_env owns, in the order it appends them.
INSTALL_MANAGED_KEYS="FOZZIE_VERSION FOZZIE_CORE_API_IMAGE FOZZIE_DASHBOARD_IMAGE FOZZIE_UPDATER_IMAGE POSTGRES_PASSWORD FOZZIE_ENCRYPTION_KEY FOZZIE_UPDATER_TOKEN CORE_API_PORT DASHBOARD_PORT GHCR_USERNAME GHCR_TOKEN COMPOSE_PROJECT FOZZIE_INSTALL_DIR"

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
  --yes, -y               Don't ask for confirmation.
  --help, -h              Show this help.

Environment:
  GHCR_USERNAME, GHCR_TOKEN   Your GitHub username and read:packages token,
                              to log in to ghcr.io without being asked.
USAGE
}

# True (0) iff name is a valid instance name: lowercase letters, digits,
# "_" and "-", starting with a letter or digit (Compose project-name
# rules, since the project is fozzie-<name>).
install_valid_name() {
  [[ "$1" =~ $INSTALL_NAME_REGEX ]]
}

# True (0) iff port is an integer from 1 to 65535, with no leading zero.
install_valid_port() {
  [[ "$1" =~ ^[123456789][0123456789]{0,4}$ ]] && [ "$1" -le 65535 ]
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
# INSTALL_IMPORT_ENV, INSTALL_YES and INSTALL_HELP (true/false). Takes
# both "--flag value" and "--flag=value". An unknown flag, a missing value
# or an invalid name or port prints why and the usage to stderr and
# returns 1. INSTALL_DIR defaults from $HOME.
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
      --name=* | --core-port=* | --dashboard-port=* | --import-env=* | --dir=*)
        flag="${1%%=*}"
        value="${1#*=}"
        shift
        ;;
      --name | --core-port | --dashboard-port | --import-env | --dir)
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
      --import-env) INSTALL_IMPORT_ENV="$value" ;;
      --dir) INSTALL_DIR="$value" ;;
    esac
  done
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

# The image-ref regex for one service (core-api, dashboard or updater):
# the same pin-by-digest shape release.ts requires.
install_image_regex() {
  printf '^ghcr\\.io/functionberry/fozzie-dist-%s@sha256:[0123456789abcdef]{64}$\n' "$1"
}

# Validates latest.env -- given as a file path, or as its text -- without
# ever sourcing or evaluating it. Skips blank lines; rejects any other line
# that isn't KEY=VALUE with no whitespace, an unknown or duplicate key, a
# version that isn't X.Y.Z and an image ref that isn't its own service's
# digest ref. All four of FOZZIE_VERSION, FOZZIE_CORE_API_IMAGE,
# FOZZIE_DASHBOARD_IMAGE and FOZZIE_UPDATER_IMAGE are required: the
# release compose file runs the updater (manifest schema 1 itself still
# allows a release without one).
# On success sets LATEST_VERSION, LATEST_CORE_API_IMAGE,
# LATEST_DASHBOARD_IMAGE and LATEST_UPDATER_IMAGE; on failure leaves them
# empty, echoes why to stderr and returns 1.
install_parse_latest_env() {
  local input="$1" text line key value re seen=" " n=0
  local version="" core="" dashboard="" updater=""
  LATEST_VERSION=""
  LATEST_CORE_API_IMAGE=""
  LATEST_DASHBOARD_IMAGE=""
  LATEST_UPDATER_IMAGE=""
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
  LATEST_VERSION="$version"
  LATEST_CORE_API_IMAGE="$core"
  LATEST_DASHBOARD_IMAGE="$dashboard"
  LATEST_UPDATER_IMAGE="$updater"
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
  esac
}

# Echoes the new .env: the existing file's lines in order, with each
# managed key (INSTALL_MANAGED_KEYS) rewritten in place at its first
# occurrence and dropped after that, every other line kept verbatim, and
# any managed key it didn't have appended. A managed key with no value is
# left out. Precedence, per key:
#   POSTGRES_PASSWORD, FOZZIE_ENCRYPTION_KEY: import, existing, candidate;
#   FOZZIE_UPDATER_TOKEN: existing, candidate;
#   CORE_API_PORT, DASHBOARD_PORT: flag, import, existing, 4000/5173;
#   FOZZIE_VERSION, FOZZIE_*_IMAGE: always LATEST_* (install_parse_latest_env);
#   GHCR_USERNAME, GHCR_TOKEN: the newly entered value, existing;
#   COMPOSE_PROJECT, FOZZIE_INSTALL_DIR (for the updater): always this
#     run's PROJECT and absolute DIR, never kept from the existing file.
# The candidates are generated by the caller, so this stays deterministic.
# Either file may be "" or missing. Returns 1, echoing why to stderr, when
# a required value is missing or a value isn't safe to write unquoted.
#   install_merge_env EXISTING IMPORT FLAG_CORE_PORT FLAG_DASHBOARD_PORT \
#     NEW_GHCR_USERNAME NEW_GHCR_TOKEN CANDIDATE_PASSWORD CANDIDATE_KEY \
#     CANDIDATE_UPDATER_TOKEN PROJECT DIR
install_merge_env() {
  local existing="$1" import="$2" flag_core="$3" flag_dash="$4"
  local new_user="$5" new_token="$6" cand_password="$7" cand_key="$8" cand_updater="$9"
  local m_COMPOSE_PROJECT="${10:-}" m_FOZZIE_INSTALL_DIR="${11:-}"
  local key value line emitted=" "
  local m_FOZZIE_VERSION="$LATEST_VERSION"
  local m_FOZZIE_CORE_API_IMAGE="$LATEST_CORE_API_IMAGE"
  local m_FOZZIE_DASHBOARD_IMAGE="$LATEST_DASHBOARD_IMAGE"
  local m_FOZZIE_UPDATER_IMAGE="$LATEST_UPDATER_IMAGE"
  local m_POSTGRES_PASSWORD m_FOZZIE_ENCRYPTION_KEY m_FOZZIE_UPDATER_TOKEN
  local m_CORE_API_PORT m_DASHBOARD_PORT m_GHCR_USERNAME m_GHCR_TOKEN

  m_POSTGRES_PASSWORD="$(install_env_get "$import" POSTGRES_PASSWORD)"
  [ -n "$m_POSTGRES_PASSWORD" ] || m_POSTGRES_PASSWORD="$(install_env_get "$existing" POSTGRES_PASSWORD)"
  [ -n "$m_POSTGRES_PASSWORD" ] || m_POSTGRES_PASSWORD="$cand_password"

  m_FOZZIE_ENCRYPTION_KEY="$(install_env_get "$import" FOZZIE_ENCRYPTION_KEY)"
  [ -n "$m_FOZZIE_ENCRYPTION_KEY" ] || m_FOZZIE_ENCRYPTION_KEY="$(install_env_get "$existing" FOZZIE_ENCRYPTION_KEY)"
  [ -n "$m_FOZZIE_ENCRYPTION_KEY" ] || m_FOZZIE_ENCRYPTION_KEY="$cand_key"

  m_FOZZIE_UPDATER_TOKEN="$(install_env_get "$existing" FOZZIE_UPDATER_TOKEN)"
  [ -n "$m_FOZZIE_UPDATER_TOKEN" ] || m_FOZZIE_UPDATER_TOKEN="$cand_updater"

  m_CORE_API_PORT="$flag_core"
  [ -n "$m_CORE_API_PORT" ] || m_CORE_API_PORT="$(install_env_get "$import" CORE_API_PORT)"
  [ -n "$m_CORE_API_PORT" ] || m_CORE_API_PORT="$(install_env_get "$existing" CORE_API_PORT)"
  [ -n "$m_CORE_API_PORT" ] || m_CORE_API_PORT=4000

  m_DASHBOARD_PORT="$flag_dash"
  [ -n "$m_DASHBOARD_PORT" ] || m_DASHBOARD_PORT="$(install_env_get "$import" DASHBOARD_PORT)"
  [ -n "$m_DASHBOARD_PORT" ] || m_DASHBOARD_PORT="$(install_env_get "$existing" DASHBOARD_PORT)"
  [ -n "$m_DASHBOARD_PORT" ] || m_DASHBOARD_PORT=5173

  m_GHCR_USERNAME="$new_user"
  [ -n "$m_GHCR_USERNAME" ] || m_GHCR_USERNAME="$(install_env_get "$existing" GHCR_USERNAME)"
  m_GHCR_TOKEN="$new_token"
  [ -n "$m_GHCR_TOKEN" ] || m_GHCR_TOKEN="$(install_env_get "$existing" GHCR_TOKEN)"

  for key in FOZZIE_VERSION FOZZIE_CORE_API_IMAGE FOZZIE_DASHBOARD_IMAGE FOZZIE_UPDATER_IMAGE POSTGRES_PASSWORD FOZZIE_ENCRYPTION_KEY FOZZIE_UPDATER_TOKEN COMPOSE_PROJECT FOZZIE_INSTALL_DIR; do
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
        printf 'The install directory %s has characters the installer cannot write safely -- only letters, digits and + / = . _ : @ - are allowed. Pick another with --dir.\n' "$value" >&2
      else
        printf '%s has characters the installer cannot write safely -- only letters, digits and + / = . _ : @ - are allowed\n' "$key" >&2
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

FOZZIE_RELEASES_URL="${FOZZIE_RELEASES_URL:-https://functionberry.github.io/fozzie-releases}"
FOZZIE_RELEASES_URL="${FOZZIE_RELEASES_URL%/}"

# Where prompts are read from and written to. Overridable only so the
# tests can make sure there's no terminal.
TTY="${FOZZIE_INSTALL_TTY:-/dev/tty}"

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

# ask PROMPT: echoes the answer read from the terminal.
ask() {
  local answer
  printf '%s' "$1" >"$TTY"
  IFS= read -r answer <"$TTY" || answer=""
  printf '%s\n' "$answer"
}

# ask_secret PROMPT: as ask, without echoing what's typed.
ask_secret() {
  local answer
  printf '%s' "$1" >"$TTY"
  IFS= read -rs answer <"$TTY" || answer=""
  printf '\n' >"$TTY"
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

# docker_login USER TOKEN: logs in to ghcr.io with the token on stdin,
# never on the command line. Leaves docker's output in LOGIN_OUTPUT.
docker_login() {
  LOGIN_OUTPUT=""
  if LOGIN_OUTPUT="$(printf '%s' "$2" | docker login ghcr.io -u "$1" --password-stdin 2>&1)"; then
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
    if docker_login "$user" "$token"; then
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

# pull_core: pulls the release's core-api image, which also proves
# the login works. Leaves docker's output in PULL_OUTPUT.
pull_core() {
  echo "Pulling $LATEST_CORE_API_IMAGE"
  if docker pull "$LATEST_CORE_API_IMAGE" </dev/null >"$WORK/pull.log" 2>&1; then
    PULL_OUTPUT=""
    return 0
  fi
  PULL_OUTPUT="$(cat "$WORK/pull.log")"
  return 1
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
  if install_needs_ports "$NAME" "$HAVE_EXISTING_PORTS" "$HAVE_IMPORT_PORTS" "$INSTALL_CORE_PORT" "$INSTALL_DASHBOARD_PORT"; then
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
  trap 'rm -rf "$WORK"; rm -f "$DIR/.env.tmp" "$DIR/docker-compose.yml.tmp"' EXIT

  # --- 3. The latest release -------------------------------------------

  log "Checking the latest Fozzie release"
  if ! curl -fsSL "$FOZZIE_RELEASES_URL/latest.env" -o "$WORK/latest.env" </dev/null; then
    die "Couldn't download $FOZZIE_RELEASES_URL/latest.env -- check your internet connection, then run this again."
  fi
  if ! install_parse_latest_env "$WORK/latest.env" 2>"$WORK/latest.err"; then
    die "The release metadata looks wrong ($(cat "$WORK/latest.err")) -- don't continue, tell Mark."
  fi
  echo "Latest release: $LATEST_VERSION"

  # --- 4. ghcr.io access -----------------------------------------------

  NEW_GHCR_USERNAME=""
  NEW_GHCR_TOKEN=""
  local logged_in=false existing_user existing_token
  existing_user="$(install_env_get "$ENV_FILE" GHCR_USERNAME)"
  existing_token="$(install_env_get "$ENV_FILE" GHCR_TOKEN)"

  if [ -n "${GHCR_USERNAME:-}" ] || [ -n "${GHCR_TOKEN:-}" ]; then
    [[ "${GHCR_USERNAME:-}" =~ $INSTALL_GHCR_USERNAME_REGEX ]] ||
      die "GHCR_USERNAME doesn't look like a GitHub username (letters, digits and - only)."
    [[ "${GHCR_TOKEN:-}" =~ $INSTALL_GHCR_TOKEN_REGEX ]] ||
      die "GHCR_TOKEN doesn't look like a GitHub token (letters, digits and _ only)."
    log "Logging in to ghcr.io as $GHCR_USERNAME"
    docker_login "$GHCR_USERNAME" "$GHCR_TOKEN" ||
      die "$(install_docker_error_message login "$LOGIN_OUTPUT" "$GHCR_USERNAME")"
    NEW_GHCR_USERNAME="$GHCR_USERNAME"
    NEW_GHCR_TOKEN="$GHCR_TOKEN"
    logged_in=true
  elif [ -n "$existing_user" ] && [ -n "$existing_token" ]; then
    if docker_login "$existing_user" "$existing_token"; then
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

  # --- 5. Existing data? -----------------------------------------------

  # Data, not .env, is what makes this an existing instance: one installed
  # from source has its volumes under this same project, but no .env here.
  local have_data=false old_version
  if docker volume inspect "${PROJECT}_fozzie_pg_local_data" </dev/null >/dev/null 2>&1; then
    have_data=true
  fi
  old_version="$(install_env_get "$ENV_FILE" FOZZIE_VERSION)"

  if [ "$have_data" = true ] && [ "$INSTALL_YES" != true ]; then
    have_tty || die "$PROJECT already has data, and there's no terminal to confirm on -- re-run with --yes."
    echo
    echo "This will replace the running containers of $PROJECT with the published"
    echo "Fozzie $LATEST_VERSION images; your data stays."
    confirm "Continue?" || die "Nothing changed."
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
    "$(openssl rand -base64 24)" "$(openssl rand -base64 32)" "$(openssl rand -hex 32)" \
    "$PROJECT" "$DIR")" ||
    die "Couldn't write $ENV_FILE."
  (
    umask 077
    printf '%s\n' "$merged" >"$DIR/.env.tmp"
  )
  chmod 600 "$DIR/.env.tmp"
  CORE_API_PORT="$(install_env_get "$DIR/.env.tmp" CORE_API_PORT)"
  DASHBOARD_PORT="$(install_env_get "$DIR/.env.tmp" DASHBOARD_PORT)"

  DC_FILE="$DIR/docker-compose.yml.tmp"
  DC_ENV="$DIR/.env.tmp"

  # --- 7. Back up before changing versions -----------------------------

  if [ "$have_data" = true ] && [ "$old_version" != "$LATEST_VERSION" ]; then
    log "Pulling the rest of Fozzie $LATEST_VERSION"
    dc pull || die "Couldn't pull the images -- nothing changed. Check the output above, then run this again."
    log "Taking a backup before switching to $LATEST_VERSION"
    if ! dc run --rm -T backup node dist/backupCli.js run; then
      echo "The backup failed -- see the output above."
      if [ "$INSTALL_YES" = true ] || ! have_tty || ! confirm "Continue WITHOUT a backup?"; then
        die "Nothing changed."
      fi
    fi
  fi

  mv "$DIR/docker-compose.yml.tmp" "$DIR/docker-compose.yml"
  mv "$DIR/.env.tmp" "$ENV_FILE"
  DC_FILE="$DIR/docker-compose.yml"
  DC_ENV="$ENV_FILE"

  # --- 8. Start ----------------------------------------------------------

  log "Starting Fozzie instance \"$NAME\""
  dc up -d

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
    die "core-api didn't become healthy within 3 minutes. Check its logs for what went wrong:" \
      "  cd \"$DIR\" && docker compose -p $PROJECT --env-file .env logs core-api"
  fi

  # --- 10. Fresh install only: hand the setup token to the browser -----

  local url="http://localhost:$DASHBOARD_PORT"
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
      url="http://localhost:$DASHBOARD_PORT/?setup_token=$token"
    fi
  fi

  # --- 11. Open the browser, and how to run it from here -----------------

  local update_args="" dc_cmd
  [ "$NAME" = local ] || update_args=" --name $NAME"
  if [ "$DIR" != "$(install_default_dir "$NAME" "${HOME:-}")" ]; then
    update_args="$update_args --dir $DIR"
  fi
  dc_cmd="cd \"$DIR\" && docker compose -p $PROJECT --env-file .env"

  log "Fozzie $LATEST_VERSION (instance \"$NAME\") is running at http://localhost:$DASHBOARD_PORT"
  echo
  if [ -n "$update_args" ]; then
    echo "Update:        curl -fsSL $FOZZIE_RELEASES_URL/install.sh | bash -s --$update_args"
  else
    echo "Update:        curl -fsSL $FOZZIE_RELEASES_URL/install.sh | bash"
  fi
  echo "Stop:          $dc_cmd stop"
  echo "Start again:   $dc_cmd up -d"
  echo "List backups:  $dc_cmd run --rm backup node dist/backupCli.js list"
  echo "Uninstall:     $dc_cmd down     (keeps your data)"
  echo "               $dc_cmd down -v  (DELETES ALL DATA, permanently)"
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
