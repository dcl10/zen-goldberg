#!/usr/bin/env bash
# First-boot provisioning, run once as root by cloud-init (runcmd).
# Output goes to /var/log/cloud-init-output.log. Never echo secrets here.
set -euxo pipefail

# shellcheck source=/dev/null
. /etc/agent/bootstrap.env # NODE_VERSION, DOTNET_CHANNEL
export DEBIAN_FRONTEND=noninteractive

# --- Block the metadata service for `agent` before anything runs as that user -------------
systemctl daemon-reload
systemctl enable --now agent-firewall.service

# --- sudoers: exactly one rule; a broken file would break sudo entirely ---------------------
if ! visudo -cf /etc/sudoers.d/agent-ctl; then
  rm -f /etc/sudoers.d/agent-ctl
  echo "invalid /etc/sudoers.d/agent-ctl removed" >&2
  exit 1
fi

# --- 2 GB swap (torch) ------------------------------------------------------------------------
if [[ ! -f /swapfile ]]; then
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >>/etc/fstab
fi

# --- gh and Docker from their apt repos -------------------------------------------------------
arch=$(dpkg --print-architecture)
# shellcheck source=/dev/null
. /etc/os-release
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod 0644 /etc/apt/keyrings/githubcli-archive-keyring.gpg /etc/apt/keyrings/docker.asc
echo "deb [arch=$arch signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  >/etc/apt/sources.list.d/github-cli.list
echo "deb [arch=$arch signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $VERSION_CODENAME stable" \
  >/etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y gh docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-ce-rootless-extras

# No root Docker daemon at all: membership of the docker group would be root-equivalent.
systemctl disable --now docker.service docker.socket containerd.service

# Ubuntu 24.04 restricts unprivileged user namespaces through AppArmor; rootlesskit needs one.
if [[ -x /usr/bin/rootlesskit ]] && ! grep -rqs rootlesskit /etc/apparmor.d/; then
  cat >/etc/apparmor.d/usr.bin.rootlesskit <<'EOF'
abi <abi/4.0>,
include <tunables/global>

/usr/bin/rootlesskit flags=(unconfined) {
  userns,

  include if exists <local/usr.bin.rootlesskit>
}
EOF
  apparmor_parser -r /etc/apparmor.d/usr.bin.rootlesskit
fi

# --- Directories --------------------------------------------------------------------------------
# write_files created the parents of deferred files as root.
chown -R agent:agent /home/agent
chown -R agent-ctl:agent-ctl /home/agent-ctl
install -d -m 0755 -o root -g root /srv/agent-work
install -d -m 0750 -o agent -g agent /srv/agent-work/repo         # agent's work tree; agent-ctl never runs git here
install -d -m 0700 -o agent -g agent /srv/agent-work/scratch      # NEEDS_INFO.md
install -d -m 2750 -o agent-ctl -g agentwork /srv/agent-work/jobs # per-job hand-over dirs, created by agent-ctl
install -d -m 0750 -o agent-ctl -g agent-ctl /var/log/agent

cat >/etc/profile.d/agent-umask.sh <<'EOF'
case "$(id -un)" in agent | agent-ctl) umask 0002 ;; esac
EOF

# --- Toolchains and rootless Docker, all as `agent` -------------------------------------------
loginctl enable-linger agent
uid=$(id -u agent)
for _ in $(seq 60); do
  [[ -S /run/user/$uid/bus ]] && break
  sleep 1
done

runuser -u agent -- env -i \
  HOME=/home/agent USER=agent LOGNAME=agent SHELL=/bin/bash LANG=C.UTF-8 \
  PATH=/home/agent/.local/bin:/usr/local/bin:/usr/bin:/bin \
  XDG_RUNTIME_DIR="/run/user/$uid" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
  bash -euxo pipefail -s -- "$NODE_VERSION" "$DOTNET_CHANNEL" <<'EOF'
node_version=$1
dotnet_channel=$2
cd "$HOME"
mkdir -p "$HOME/.local/bin" "$HOME/.claude" "$HOME/out"

# Claude Code and uv (both into ~/.local/bin)
curl -fsSL https://claude.ai/install.sh | bash
curl -LsSf https://astral.sh/uv/install.sh | sh
uv python install 3.11 3.12

# Node.js via fnm, per user
curl -fsSL https://fnm.vercel.app/install | bash -s -- --skip-shell
fnm="$HOME/.local/share/fnm/fnm"
if [ "$node_version" = lts-latest ]; then
  node_version=$("$fnm" ls-remote --lts | tail -n 1 | awk '{print $1}')
fi
"$fnm" install "$node_version"
"$fnm" default "$node_version"
export PATH="$HOME/.local/share/fnm/aliases/default/bin:$PATH"
node --version
# corepack (pnpm/yarn) is no longer bundled with newer Node releases.
command -v corepack >/dev/null || npm install -g corepack
corepack enable

# .NET SDK, per user; dotnet-install.sh stays on PATH for repos that pin an SDK (global.json).
curl -fsSL https://dot.net/v1/dotnet-install.sh -o "$HOME/.local/bin/dotnet-install.sh"
chmod +x "$HOME/.local/bin/dotnet-install.sh"
"$HOME/.local/bin/dotnet-install.sh" --channel "$dotnet_channel" --install-dir "$HOME/.dotnet"
DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 "$HOME/.dotnet/dotnet" --info >/dev/null

# Rootless Docker (user systemd service, kept running by linger)
dockerd-rootless-setuptool.sh install
systemctl --user enable --now docker
EOF

# Weekly: drop Docker images/containers unused for a week, so cached images don't fill the disk.
cat >/etc/cron.d/agent-docker-prune <<EOF
30 4 * * 0 agent XDG_RUNTIME_DIR=/run/user/$uid DOCKER_HOST=unix:///run/user/$uid/docker.sock /usr/bin/docker system prune -af --filter until=168h >/dev/null 2>&1
EOF
chmod 0644 /etc/cron.d/agent-docker-prune

# --- Start polling ------------------------------------------------------------------------------
systemctl daemon-reload
systemctl enable --now agent-poll.timer
echo "helix-agent bootstrap finished"
