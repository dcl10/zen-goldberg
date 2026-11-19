#!/usr/bin/env bash
# Runs one Claude Code job as the `agent` user. This is the only command agent-ctl may sudo to:
#
#   sudo -u agent /opt/agent/run-claude.sh <job-dir> <model> <max-turns> <branch> <min-quota>
#
# agent never holds the GitHub token. Work crosses back to agent-ctl only through files that
# agent-ctl pre-created in the job dir (which agent can't create, rename or symlink in):
#   in:  prompt.md, base.bundle (ref refs/jobs/base = the commit to start from)
#   out: events.jsonl (claude's stream-json events), changes.bundle (new commits), needs-info.md
#
# Exits 75 without running Claude when the model key has fewer than <min-quota> tokens of daily
# quota left (0 skips the check). agent-poll.sh treats that as a rate limit.
set -euo pipefail
umask 0002

die() {
  printf 'run-claude: %s\n' "$*" >&2
  exit 2
}

[[ $# -eq 5 ]] || die "usage: run-claude.sh <job-dir> <model> <max-turns> <branch> <min-quota>"
job=$1 model=$2 turns=$3 branch=$4 min_quota=$5
[[ $job =~ ^/srv/agent-work/jobs/[A-Za-z0-9._-]+$ && -d $job && ! -L $job ]] || die "bad job dir: $job"
[[ $model =~ ^[A-Za-z0-9._-]+$ ]] || die "bad model: $model"
[[ $turns =~ ^[0-9]+$ ]] || die "bad max-turns: $turns"
[[ $branch =~ ^agent/issue-[0-9]+$ ]] || die "bad branch: $branch"
[[ $min_quota =~ ^[0-9]{1,12}$ ]] || die "bad min-quota: $min_quota"

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

# --- Pre-flight: enough daily quota for a run? ----------------------------------------------
# DO's tokens_per_day bucket refills slowly. A run started with too little left doesn't fail:
# it crawls from one 429 retry to the next until the job timeout, using up what does refill.
# A 1-token request reads what's left from the response headers. If the check itself breaks,
# run anyway: CLAUDE_CODE_MAX_RETRIES still makes a real 429 end the run quickly.
quota_check() {
  local url data hdrs status remaining
  ((min_quota > 0)) || return 0
  url=$(jq -r '.env.ANTHROPIC_BASE_URL // empty' "$HOME/.claude/settings.json" 2>/dev/null) || url=
  if [[ $url != https://* ]]; then
    printf 'run-claude: quota check skipped: no ANTHROPIC_BASE_URL in settings.json\n' >&2
    return 0
  fi
  data=$(jq -cn --arg m "$model" '{model: $m, max_tokens: 1, messages: [{role: "user", content: "hi"}]}')
  # The key goes to curl on stdin (-H @-), never on its command line.
  if ! hdrs=$(printf 'x-api-key: %s\n' "$(cat /etc/agent/model-key)" |
    curl -sS -m 30 -o /dev/null -D - -H @- -H 'anthropic-version: 2023-06-01' \
      -H 'content-type: application/json' --data "$data" "${url%/}/v1/messages"); then
    printf 'run-claude: quota check request failed; running anyway\n' >&2
    return 0
  fi
  hdrs=${hdrs//$'\r'/}
  status=$(awk 'toupper($1) ~ /^HTTP\// { s = $2 } END { print s }' <<<"$hdrs")
  remaining=$(awk -F': *' 'tolower($1) == "x-ratelimit-remaining-tokens-per-day" { r = $2 } END { print r }' <<<"$hdrs")
  [[ $status == 429 && ! $remaining =~ ^[0-9]+$ ]] && remaining=0
  if [[ ! $remaining =~ ^[0-9]+$ ]]; then
    printf 'run-claude: quota check got HTTP %s and no remaining-tokens header; running anyway\n' "${status:-?}" >&2
    return 0
  fi
  # agent-poll.sh reads this line back for its comment; keep the format.
  printf 'run-claude: quota %s tokens left today (need %s)\n' "$remaining" "$min_quota" >&2
  ((remaining >= min_quota)) || exit 75
}
quota_check

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
# stream-json writes each event as it happens, so a run killed by the job timeout still leaves
# its token usage, API retries and last message behind (plain json only prints at the end).
setsid claude -p \
  --model "$model" \
  --max-turns "$turns" \
  --output-format stream-json \
  --verbose \
  --dangerously-skip-permissions \
  <"$job/prompt.md" >"$job/events.jsonl" &
claude_pid=$!
rc=0
wait "$claude_pid" || rc=$?
exit "$rc"
