#!/usr/bin/env bash
#
# setup-ado-agent.sh - register and run a self-hosted Azure DevOps agent.
#
# Companion to test-trigger-pipeline.yml, which targets `pool: name: Default`. Without at least
# one online agent in that pool, every queued build fails immediately with:
#
#     No agent found in pool Default which satisfies the specified demands:
#     Agent.Version -gtVersion 2.163.1
#
# That is a scheduling failure, not a build failure: no stage ever starts, so Azure DevOps
# publishes only the rollup check run and no per-stage legs. The pipeline-analysis fix-validation
# workflow compares per-stage legs, so it cannot evaluate anything until a real agent runs the
# build. This script gets an agent online.
#
# It wraps the agent's own `config.sh` rather than replacing it: it resolves the current agent
# release, downloads the right package for this machine, runs `config.sh` unattended, and then
# either installs a service or runs in the foreground.
#
# USAGE
#   export AZP_URL=https://dev.azure.com/<your-org>
#   export AZP_TOKEN=<personal-access-token>
#   ./setup-ado-agent.sh
#
# The PAT needs the **Agent Pools (Read & manage)** scope. Create one at
#   https://dev.azure.com/<your-org>/_usersSettings/tokens
# A PAT is only needed to *register* the agent; it is exchanged for its own credentials during
# configuration and is not required afterwards.
#
# OPTIONS (environment variables)
#   AZP_URL     required  Azure DevOps organization URL, e.g. https://dev.azure.com/contoso
#   AZP_TOKEN   required  PAT with Agent Pools (Read & manage)
#   AZP_POOL    default: Default      Agent pool to join; must match the pipeline's `pool: name:`
#   AZP_AGENT_NAME  default: <hostname>-agent
#   AZP_WORK    default: _work        Agent working directory
#   AZP_DIR     default: $HOME/azp-agent   Where the agent is installed
#   AZP_VERSION default: latest release    Pin an agent version, e.g. 5.276.0
#   AZP_MODE    default: run
#                 run     - configure, then run in the foreground (Ctrl-C to stop)
#                 service - configure, then install and start a systemd service (needs sudo)
#                 config  - configure only, do not start
#
# The agent pool is a *self-hosted* pool: the build runs on this machine. Anything the pipeline
# does, it does here. Only point this at a pool you control.

set -euo pipefail

AZP_POOL="${AZP_POOL:-Default}"
AZP_AGENT_NAME="${AZP_AGENT_NAME:-$(hostname)-agent}"
AZP_WORK="${AZP_WORK:-_work}"
AZP_DIR="${AZP_DIR:-$HOME/azp-agent}"
AZP_MODE="${AZP_MODE:-run}"

fail() { echo "error: $*" >&2; exit 1; }
note() { echo "==> $*"; }

[ -n "${AZP_URL:-}" ]   || fail "AZP_URL is not set (e.g. https://dev.azure.com/contoso)."
[ -n "${AZP_TOKEN:-}" ] || fail "AZP_TOKEN is not set. Create a PAT with the 'Agent Pools (Read & manage)' scope."

case "$AZP_MODE" in run|service|config) ;; *) fail "AZP_MODE must be one of: run, service, config." ;; esac

# --- Resolve the platform ------------------------------------------------------------------
# Package names follow vsts-agent-<os>-<arch>-<version>.<ext>.
case "$(uname -s)" in
  Linux)  AGENT_OS="linux" ;  EXT="tar.gz" ;;
  Darwin) AGENT_OS="osx"   ;  EXT="tar.gz" ;;
  *) fail "Unsupported OS '$(uname -s)'. On Windows use config.cmd from the agent package instead." ;;
esac

case "$(uname -m)" in
  x86_64|amd64)  AGENT_ARCH="x64" ;;
  aarch64|arm64) AGENT_ARCH="arm64" ;;
  armv7l)        AGENT_ARCH="arm" ;;
  *) fail "Unsupported architecture '$(uname -m)'." ;;
esac

# --- Resolve the agent version -------------------------------------------------------------
if [ -n "${AZP_VERSION:-}" ]; then
  AGENT_VERSION="${AZP_VERSION#v}"
else
  note "Resolving the latest agent release..."
  AGENT_VERSION="$(
    curl -fsSL https://api.github.com/repos/microsoft/azure-pipelines-agent/releases/latest |
      sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' | head -1
  )" || true
  [ -n "$AGENT_VERSION" ] || fail "Could not resolve the latest agent version. Set AZP_VERSION explicitly."
fi

# The historical vstsagentpackage.azureedge.net CDN has been retired and now fails to resolve;
# download.agent.dev.azure.com is the current host.
PKG="vsts-agent-${AGENT_OS}-${AGENT_ARCH}-${AGENT_VERSION}.${EXT}"
URL="https://download.agent.dev.azure.com/agent/${AGENT_VERSION}/${PKG}"

note "Agent      : ${AGENT_VERSION} (${AGENT_OS}-${AGENT_ARCH})"
note "Organization: ${AZP_URL}"
note "Pool        : ${AZP_POOL}"
note "Agent name  : ${AZP_AGENT_NAME}"
note "Install dir : ${AZP_DIR}"

# --- Download and unpack --------------------------------------------------------------------
mkdir -p "$AZP_DIR"
cd "$AZP_DIR"

if [ ! -f "./config.sh" ]; then
  note "Downloading ${URL}"
  curl -fSL --retry 3 -o "$PKG" "$URL" || fail "Download failed. Check the version and your network."
  note "Extracting ${PKG}"
  tar -xzf "$PKG"
  rm -f "$PKG"
else
  note "An agent is already unpacked in ${AZP_DIR}; reusing it."
fi

# The agent refuses to configure or run as root, and says so only after a long preamble.
if [ "$(id -u)" -eq 0 ]; then
  fail "Do not run this script as root. The Azure Pipelines agent refuses to configure as root; run it as a normal user (service install uses sudo separately)."
fi

if [ -x "./bin/installdependencies.sh" ] && [ "$AGENT_OS" = "linux" ]; then
  note "Installing agent OS dependencies (requires sudo; skipping on failure)."
  sudo ./bin/installdependencies.sh || note "Dependency install failed or was skipped; continuing."
fi

# --- Configure --------------------------------------------------------------------------------
# `--replace` lets a re-run take over an existing registration with the same name instead of
# erroring. `--acceptTeeEula` is required on Linux/macOS. `--unattended` makes it non-interactive.
if [ -f ".agent" ]; then
  note "Agent already configured; reconfiguring to pick up current settings."
  ./config.sh remove --unattended --auth pat --token "$AZP_TOKEN" || note "Remove failed; continuing to reconfigure."
fi

note "Configuring the agent..."
./config.sh \
  --unattended \
  --acceptTeeEula \
  --url "$AZP_URL" \
  --auth pat \
  --token "$AZP_TOKEN" \
  --pool "$AZP_POOL" \
  --agent "$AZP_AGENT_NAME" \
  --work "$AZP_WORK" \
  --replace

note "Agent configured."

case "$AZP_MODE" in
  config)
    note "AZP_MODE=config; not starting. Start later with: (cd '$AZP_DIR' && ./run.sh)"
    ;;
  service)
    note "Installing and starting the systemd service (requires sudo)."
    sudo ./svc.sh install "$(whoami)"
    sudo ./svc.sh start
    sudo ./svc.sh status || true
    note "Agent is running as a service and will survive reboots."
    ;;
  run)
    note "Starting the agent in the foreground. Leave this running; Ctrl-C stops it."
    note "The agent must be online for queued builds to start."
    ./run.sh
    ;;
esac
