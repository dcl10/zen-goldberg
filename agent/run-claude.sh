#!/usr/bin/env bash
# Runs one Claude Code job as the `agent` user. This is the only command agent-ctl may sudo to:
#
#   sudo -u agent /opt/agent/run-claude.sh <job-dir> <model> <max-turns> <branch>
#
# agent never holds the GitHub token. Work crosses back to agent-ctl only through files that
# agent-ctl pre-created in the job dir (which agent can't create, rename or symlink in):
#   in:  prompt.md, base.bundle (ref refs/jobs/base = the commit to start from)
#   out: result.json (claude's JSON), changes.bundle (new commits), needs-info.md
set -euo pipefail
umask 0002

die() {
  printf 'run-claude: %s\n' "$*" >&2
  exit 2
}

[[ $# -eq 4 ]] || die "usage: run-claude.sh <job-dir> <model> <max-turns> <branch>"
job=$1 model=$2 turns=$3 branch=$4
[[ $job =~ ^/srv/agent-work/jobs/[A-Za-z0-9._-]+$ && -d $job && ! -L $job ]] || die "bad job dir: $job"
[[ $model =~ ^[A-Za-z0-9._-]+$ ]] || die "bad model: $model"
[[ $turns =~ ^[0-9]+$ ]] || die "bad max-turns: $turns"
[[ $branch =~ ^agent/issue-[0-9]+$ ]] || die "bad branch: $branch"

uid=$(id -u)
export HOME=/home/agent USER=agent LOGNAME=agent SHELL=/bin/bash LANG=C.UTF-8
export PATH="$HOME/.local/bin:$HOME/.local/share/fnm/aliases/default/bin:$HOME/.dotnet:$HOME/.dotnet/tools:/usr/local/bin:/usr/bin:/bin"
export FNM_DIR="$HOME/.local/share/fnm"
export DOTNET_ROOT="$HOME/.dotnet" DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
export XDG_RUNTIME_DIR="/run/user/$uid" DOCKER_HOST="unix:///run/user/$uid/docker.sock"

repo=/srv/agent-work/repo
needs=/srv/agent-work/scratch/NEEDS_INFO.md
base=
claude_pid=

# Always: hand back commits and questions, then remove every container so none outlive the job.
# Images and volumes stay as a cache.
finish() {
  local rc=$?
  set +e
  [[ -n $claude_pid ]] && kill -KILL -- "-$claude_pid" 2>/dev/null
  if [[ -n $base ]] && cd "$repo"; then
    git add -A -- . ':(exclude,glob)**/.env' ':(exclude,glob)**/.env.*'
    git diff --cached --quiet || git commit -q -m "Commit changes the agent left uncommitted"
    git update-ref "refs/heads/$branch" HEAD
    if [[ -n $(git rev-list -n 1 "$base..$branch") ]]; then
      git bundle create -q - "refs/heads/$branch" "^$base" >"$job/changes.bundle"
    fi
  fi
  if [[ -f $needs && ! -L $needs ]]; then
    head -c 65536 "$needs" >"$job/needs-info.md"
  fi
  timeout 60 docker ps -aq | xargs -r timeout 120 docker rm -f >/dev/null
  timeout 60 docker network prune -f >/dev/null
  exit "$rc"
}
trap finish EXIT

# On timeout (TERM from sudo), give Claude a moment to stop, then let finish() clean up.
on_signal() {
  if [[ -n $claude_pid ]]; then
    kill -TERM -- "-$claude_pid" 2>/dev/null
    wait "$claude_pid" 2>/dev/null
  fi
  exit 143
}
trap on_signal TERM INT

# --- Prepare the work tree from the base bundle --------------------------------------------------
cd "$repo"
[[ -d .git ]] || git init -q
rm -f .git/index.lock
git fetch -q --no-tags "$job/base.bundle" refs/jobs/base
fetched=$(git rev-parse FETCH_HEAD)
git checkout -q -f -B "$branch" "$fetched"
git reset -q --hard "$fetched"
git clean -q -ffdx -e .venv
rm -f "$needs"
base=$fetched

# --- Run Claude (in its own process group, in the background, so signals reach the trap) -----
setsid claude -p \
  --model "$model" \
  --max-turns "$turns" \
  --output-format json \
  --dangerously-skip-permissions \
  <"$job/prompt.md" >"$job/result.json" &
claude_pid=$!
rc=0
wait "$claude_pid" || rc=$?
exit "$rc"
