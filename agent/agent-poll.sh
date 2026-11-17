#!/usr/bin/env bash
# Helix Reborn agent: one poll tick. Runs as the unprivileged agent-ctl user (agent-poll.service).
#
# agent-ctl holds the bot's GitHub token and does every git fetch/push and gh call. It never
# runs the model itself (run-claude.sh does that, as `agent`), and it never runs git inside a
# repo `agent` can write: commits come back as a bundle that is fetched into agent-ctl's own
# private clone. At most one model job per tick:
#   0. housekeeping   1. merge approved PRs   2. revise one PR   3. start one queued issue
set -euo pipefail
shopt -s inherit_errexit
umask 0027

: "${AGENT_REPO:?}" "${AGENT_DEFAULT_BRANCH:?}" "${AGENT_OWNER:?}" "${AGENT_BOT:?}" "${AGENT_MODEL:?}"
: "${AGENT_MAX_TURNS:?}" "${AGENT_JOB_TIMEOUT:?}" "${AGENT_AUTO_MERGE:?}" "${GH_TOKEN:?}"

R=$AGENT_REPO
REPO_OWNER=${R%%/*}
STATE_DIR=${STATE_DIRECTORY:-/var/lib/agent-ctl}
CLONE=$STATE_DIR/repo.git
JOBS=/srv/agent-work/jobs
NEEDS_INFO=/srv/agent-work/scratch/NEEDS_INFO.md
LOG_DIR=/var/log/agent
PROMPTS=/opt/agent
LOCK=${RUNTIME_DIRECTORY:-/run/agent-poll}/lock
MAX_BODY=60000

export GH_REPO=$R GH_CONFIG_DIR=$STATE_DIR/gh GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 NO_COLOR=1
export GIT_TERMINAL_PROMPT=0
# The token reaches git only through environment-supplied config, never a .git/config file.
# Hooks are off for every git command agent-ctl runs.
basic=$(printf 'x-access-token:%s' "$GH_TOKEN" | base64 -w0)
export GIT_CONFIG_COUNT=2 \
  GIT_CONFIG_KEY_0=http.https://github.com/.extraheader \
  GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $basic" \
  GIT_CONFIG_KEY_1=core.hooksPath \
  GIT_CONFIG_VALUE_1=/dev/null
unset basic

log() { printf '%s\n' "$*" >&2; } # journald adds timestamps

# ---------------------------------------------------------------------------------------------
# GitHub helpers
# ---------------------------------------------------------------------------------------------

api() { gh api "$@"; }

# Every page of a list endpoint, as one JSON array.
api_all() { gh api --paginate "$1" | jq -s 'add // []'; }

label_add() { api -X POST "repos/$R/issues/$1/labels" -f "labels[]=$2" >/dev/null; }
label_rm() { api -X DELETE "repos/$R/issues/$1/labels/${2//:/%3A}" >/dev/null 2>&1 || true; }

# comment <number>; body on stdin (issues and PRs share the endpoint).
comment() { head -c "$MAX_BODY" | api -X POST "repos/$R/issues/$1/comments" -F body=@- >/dev/null; }

# has_label <json-with-.labels> <name>
has_label() { jq -e --arg l "$2" 'any(.labels[]; .name == $l)' <<<"$1" >/dev/null; }

# Login of whoever most recently added label <name> to issue/PR <n> ("" if never).
last_labeler() {
  api_all "repos/$R/issues/$1/events?per_page=100" |
    jq -r --arg l "$2" '[.[] | select(.event == "labeled" and .label.name == $l)] | last | .actor.login // ""'
}

# The owner's latest review that sets a state (COMMENTED reviews don't), as JSON ({} if none).
owner_latest_review() {
  api_all "repos/$R/pulls/$1/reviews?per_page=100" |
    jq -c --arg o "$AGENT_OWNER" '[.[] | select(.user.login == $o and (.state == "APPROVED" or .state == "CHANGES_REQUESTED" or .state == "DISMISSED"))] | last // {}'
}

# max(last commit date, bot's last comment) on PR <n>, as an ISO timestamp ("" if neither).
bot_last_activity() {
  local c m
  c=$(api_all "repos/$R/pulls/$1/commits?per_page=100" | jq -r 'map(.commit.committer.date) | max // ""')
  m=$(api_all "repos/$R/issues/$1/comments?per_page=100" |
    jq -r --arg b "$AGENT_BOT" 'map(select(.user.login == $b) | .created_at) | max // ""')
  printf '%s\n%s\n' "$c" "$m" | sort | tail -n 1
}

# Comments by the owner on issue/PR <n>, as markdown ("" if none).
owner_comments_md() {
  api_all "repos/$R/issues/$1/comments?per_page=100" |
    jq -r --arg o "$AGENT_OWNER" '.[] | select(.user.login == $o) | "### Comment, \(.created_at)\n\n\(.body // "")\n"'
}

# ---------------------------------------------------------------------------------------------
# git (agent-ctl's private clone only) and jobs
# ---------------------------------------------------------------------------------------------

sync_clone() {
  if [[ ! -d $CLONE ]]; then
    git init -q --bare "$CLONE"
    git -C "$CLONE" remote add origin "https://github.com/$R.git"
  fi
  git -C "$CLONE" fetch -q --prune --no-tags origin
}

# new_job <name> <base-sha>: create the hand-over dir and print its path.
new_job() {
  local job
  job="$JOBS/$(date -u +%Y%m%dT%H%M%SZ)-$1"
  install -d -m 2750 "$job"
  git -C "$CLONE" update-ref refs/jobs/base "$2"
  git -C "$CLONE" bundle create -q "$job/base.bundle" refs/jobs/base
  chmod 0640 "$job/base.bundle"
  local f
  for f in result.json needs-info.md changes.bundle; do
    : >"$job/$f"
    chmod 0660 "$job/$f"
  done
  printf '%s\n' "$job"
}

# run_job <job-dir> <branch> <base-sha>. Sets JOB_RC, JOB_COMMITS, JOB_HEAD, JOB_IS_ERROR,
# JOB_SUBTYPE, JOB_RESULT (Claude's final message) and JOB_NEEDS (clarification questions).
# Everything read back from the job dir was written by `agent`: treat it as untrusted data.
run_job() {
  local job=$1 branch=$2 base=$3 id
  id=$(basename "$job")
  chmod 0640 "$job/prompt.md"
  log "job $id: $AGENT_MODEL on $branch from ${base:0:12}"

  JOB_RC=0
  timeout --kill-after=2m "$AGENT_JOB_TIMEOUT" \
    sudo -n -u agent /opt/agent/run-claude.sh "$job" "$AGENT_MODEL" "$AGENT_MAX_TURNS" "$branch" \
    >"$LOG_DIR/$id.log" 2>&1 || JOB_RC=$?

  cp "$job/result.json" "$LOG_DIR/$id.json"
  if jq -e 'type == "object"' "$job/result.json" >/dev/null 2>&1; then
    JOB_SUBTYPE=$(jq -r '.subtype // "unknown" | tostring' "$job/result.json")
    JOB_IS_ERROR=$(jq -r 'if .is_error == false then "false" else "true" end' "$job/result.json")
    JOB_RESULT=$(jq -r '.result // "" | tostring' "$job/result.json")
    log "job $id: exit $JOB_RC $(jq -c '{subtype, is_error, num_turns, duration_ms, usage}' "$job/result.json")"
  else
    JOB_SUBTYPE=no_output JOB_IS_ERROR=true JOB_RESULT=
    log "job $id: exit $JOB_RC, no JSON output (see $LOG_DIR/$id.log)"
  fi
  JOB_NEEDS=$(head -c "$MAX_BODY" "$job/needs-info.md")

  JOB_COMMITS=0 JOB_HEAD=$base
  if [[ -s $job/changes.bundle ]]; then
    if git -C "$CLONE" bundle verify -q "$job/changes.bundle" >/dev/null 2>&1 &&
      git -C "$CLONE" fetch -q --no-tags "$job/changes.bundle" "+refs/heads/$branch:refs/jobs/result"; then
      local head
      head=$(git -C "$CLONE" rev-parse refs/jobs/result)
      if git -C "$CLONE" merge-base --is-ancestor "$base" "$head"; then
        JOB_HEAD=$head
        JOB_COMMITS=$(git -C "$CLONE" rev-list --count "$base..$head")
      else
        log "job $id: returned commits don't descend from the base; ignored"
      fi
    else
      log "job $id: unreadable changes bundle; ignored"
    fi
  fi
  log "job $id: $JOB_COMMITS new commit(s)"
}

job_failed() { [[ $JOB_RC -ne 0 || $JOB_IS_ERROR == true ]]; }

# push <sha> <branch> [--force]
push() {
  git -C "$CLONE" push -q ${3:+"$3"} origin "$1:refs/heads/$2"
}

PUSH_HINT="The push was rejected. If the change touches .github/workflows, the bot's token can't push it (no workflow scope)."

# ---------------------------------------------------------------------------------------------
# 0. Housekeeping
# ---------------------------------------------------------------------------------------------

housekeeping() {
  find "$JOBS" -mindepth 1 -maxdepth 1 -mtime +2 -exec rm -rf {} +
  find "$LOG_DIR" -type f -mtime +30 -delete

  # We hold the lock, so anything still marked working was interrupted. Never re-add `agent`.
  local n
  for n in $(api_all "repos/$R/issues?state=all&labels=agent%3Aworking&per_page=100" | jq -r '.[].number'); do
    log "#$n: interrupted run; marking failed"
    label_rm "$n" agent:working
    label_add "$n" agent:failed
    echo 'The agent was interrupted while working on this. Re-add `agent` to retry.' | comment "$n"
  done
}

# ---------------------------------------------------------------------------------------------
# Bot PRs
# ---------------------------------------------------------------------------------------------

bot_prs() {
  api_all "repos/$R/pulls?state=open&per_page=100" |
    jq -c --arg b "$AGENT_BOT" '[.[] | select(.user.login == $b
      and (.head.ref | test("^agent/issue-[0-9]+$"))
      and (.draft | not)
      and .head.repo.full_name == .base.repo.full_name)] | sort_by(.number) | .[]'
}

# ---------------------------------------------------------------------------------------------
# 1. Merge
# ---------------------------------------------------------------------------------------------

merge_approved() {
  local pr n sha ref review view state
  while read -r pr; do
    [[ -n $pr ]] || continue
    n=$(jq -r .number <<<"$pr")
    has_label "$pr" agent:working && continue
    review=$(owner_latest_review "$n")
    view=$(gh pr view "$n" --json headRefOid,headRefName,mergeStateStatus)
    sha=$(jq -r .headRefOid <<<"$view")
    ref=$(jq -r .headRefName <<<"$view")
    [[ $(jq -r '.state // ""' <<<"$review") == APPROVED && $(jq -r '.commit_id // ""' <<<"$review") == "$sha" ]] || continue
    state=$(jq -r .mergeStateStatus <<<"$view")
    case $state in
      CLEAN | HAS_HOOKS) ;;
      *)
        log "PR #$n: approved but merge state is $state; waiting"
        continue
        ;;
    esac
    if ! api -X PUT "repos/$R/pulls/$n/merge" -f merge_method=squash -f sha="$sha" >/dev/null; then
      log "PR #$n: merge failed; will retry next tick"
      continue
    fi
    log "PR #$n: merged"
    api -X DELETE "repos/$R/git/refs/heads/$ref" >/dev/null 2>&1 || true
    label_rm "${ref#agent/issue-}" agent:review
  done < <(bot_prs)
}

# ---------------------------------------------------------------------------------------------
# 2. Revise
# ---------------------------------------------------------------------------------------------

revise_one() {
  local pr n reason last review labeler
  while read -r pr; do
    [[ -n $pr ]] || continue
    n=$(jq -r .number <<<"$pr")
    has_label "$pr" agent:working && continue
    reason= last=
    if has_label "$pr" agent; then
      labeler=$(last_labeler "$n" agent)
      if [[ $labeler == "$AGENT_OWNER" ]]; then
        reason="the agent label"
      else
        log "PR #$n: agent label added by '$labeler', not $AGENT_OWNER; ignoring it"
      fi
    fi
    if [[ -z $reason ]] && ! has_label "$pr" agent:failed; then
      review=$(owner_latest_review "$n")
      if [[ $(jq -r '.state // ""' <<<"$review") == CHANGES_REQUESTED ]]; then
        last=$(bot_last_activity "$n")
        [[ $(jq -r .submitted_at <<<"$review") > "$last" ]] && reason="a changes-requested review"
      fi
    fi
    if [[ -n $reason ]]; then
      log "PR #$n: revising (triggered by $reason)"
      do_revise "$pr"
      RAN_JOB=1
      return
    fi
  done < <(bot_prs)
}

do_revise() {
  local pr=$1 n branch issue sha title last job prompt feedback
  n=$(jq -r .number <<<"$pr")
  branch=$(jq -r .head.ref <<<"$pr")
  sha=$(jq -r .head.sha <<<"$pr")
  title=$(jq -r .title <<<"$pr")
  issue=${branch#agent/issue-}

  label_rm "$n" agent
  label_rm "$n" agent:failed
  label_add "$n" agent:working

  last=$(bot_last_activity "$n")
  git -C "$CLONE" cat-file -e "$sha^{commit}"
  job=$(new_job "pr-$n" "$sha")

  feedback=$(
    {
      api_all "repos/$R/pulls/$n/reviews?per_page=100" |
        jq --arg o "$AGENT_OWNER" '[.[] | select(.user.login == $o and (.body // "") != "")
          | {t: .submitted_at, what: "Review (\(.state | ascii_downcase | gsub("_"; " ")))", body}]'
      api_all "repos/$R/pulls/$n/comments?per_page=100" |
        jq --arg o "$AGENT_OWNER" '[.[] | select(.user.login == $o)
          | {t: .created_at, what: "Inline comment on `\(.path):\(.line // .original_line // "?")`", body}]'
      api_all "repos/$R/issues/$n/comments?per_page=100" |
        jq --arg o "$AGENT_OWNER" '[.[] | select(.user.login == $o)
          | {t: .created_at, what: "PR comment", body}]'
    } | jq -s -r --arg last "$last" 'add | sort_by(.t) | .[]
          | "### \(if .t > $last then "[NEW] " else "" end)\(.what), \(.t)\n\n\(.body)\n"'
  )

  {
    printf '# Revise pull request #%s: %s\n\n' "$n" "$title"
    printf 'You are on branch `%s`, which already holds your earlier work for issue #%s.\n\n' "$branch" "$issue"
    printf '## Original issue #%s\n\n' "$issue"
    api "repos/$R/issues/$issue" -q '.body // "(no body)"'
    printf '\n\n## Pull request description\n\n'
    jq -r '.body // "(no description)"' <<<"$pr"
    printf '\n\n## Feedback from @%s (oldest first; [NEW] = since your last update)\n\n' "$AGENT_OWNER"
    if [[ -n $feedback ]]; then printf '%s\n' "$feedback"; else printf '(No written feedback: @%s asked for another pass.)\n' "$AGENT_OWNER"; fi
    printf '\n## Clarification file\n\nIf you need answers before you can act, write your questions to `%s`.\n\n---\n\n' "$NEEDS_INFO"
    cat "$PROMPTS/prompt-revise.md"
  } >"$job/prompt.md"

  run_job "$job" "$branch" "$sha"

  local pushed=true failed=false body
  if ((JOB_COMMITS > 0)); then
    push "$JOB_HEAD" "$branch" || pushed=false
  fi
  if job_failed || [[ $pushed == false ]]; then failed=true; fi

  if [[ -n $JOB_NEEDS ]]; then
    body=$JOB_NEEDS
  elif [[ -n $JOB_RESULT ]]; then
    body=$JOB_RESULT
  else
    body="(The run ended without a summary.)"
  fi
  {
    if [[ $failed == true ]]; then
      printf '**This revision run failed** (`%s`, exit %s). Re-add `agent` to retry.\n\n' "$JOB_SUBTYPE" "$JOB_RC"
      [[ $pushed == false ]] && printf '%s\n\n' "$PUSH_HINT"
      ((JOB_COMMITS > 0)) && [[ $pushed == true ]] && printf 'Partial work (%s commit(s)) was pushed.\n\n' "$JOB_COMMITS"
    fi
    printf '%s\n' "$body"
  } | comment "$n"

  [[ $failed == true ]] && label_add "$n" agent:failed
  label_rm "$n" agent:working
  log "PR #$n: revision done (failed=$failed, commits=$JOB_COMMITS)"
}

# ---------------------------------------------------------------------------------------------
# 3. Pick up the next issue the owner queued
# ---------------------------------------------------------------------------------------------

# Open blockers of issue <n> (native dependencies + "blocked by / depends on #N" in <body>).
open_blockers() {
  local n=$1 body=$2 m state
  {
    { api_all "repos/$R/issues/$n/dependencies/blocked_by?per_page=100" 2>/dev/null || echo '[]'; } |
      jq -r '.[] | select(.state == "open") | .number'
    for m in $(grep -oiE '(blocked by|depends on)[: ]*#[0-9]+([ ,]*(and|&)?[ ,]*#[0-9]+)*' <<<"$body" | grep -oE '[0-9]+' | sort -u); do
      [[ $m == "$n" ]] && continue
      state=$(api "repos/$R/issues/$m" -q .state 2>/dev/null || echo missing)
      [[ $state == open ]] && echo "$m"
    done
    true
  } | sort -nu | paste -sd' ' -
}

pick_issue() {
  local issue n labeler blockers
  while read -r issue; do
    [[ -n $issue ]] || continue
    n=$(jq -r .number <<<"$issue")
    labeler=$(last_labeler "$n" agent)
    if [[ $labeler != "$AGENT_OWNER" ]]; then
      log "#$n: skipped, agent label last added by '$labeler', not $AGENT_OWNER"
      continue
    fi
    blockers=$(open_blockers "$n" "$(jq -r '.body // ""' <<<"$issue")")
    if [[ -n $blockers ]]; then
      log "#$n: blocked by $blockers"
      has_label "$issue" agent:blocked || label_add "$n" agent:blocked
      continue
    fi
    has_label "$issue" agent:blocked && label_rm "$n" agent:blocked
    do_issue "$issue"
    RAN_JOB=1
    return
  done < <(api_all "repos/$R/issues?state=open&labels=agent&creator=$AGENT_OWNER&sort=created&direction=asc&per_page=100" |
    jq -c --arg o "$AGENT_OWNER" '.[] | select((.pull_request | not) and .user.login == $o)')
}

do_issue() {
  local issue=$1 n title branch base job comments
  n=$(jq -r .number <<<"$issue")
  title=$(jq -r .title <<<"$issue")
  branch=agent/issue-$n
  log "#$n: starting ($title)"

  label_rm "$n" agent
  label_rm "$n" agent:failed
  label_rm "$n" agent:needs-info
  label_add "$n" agent:working

  base=$(git -C "$CLONE" rev-parse "refs/remotes/origin/$AGENT_DEFAULT_BRANCH")
  job=$(new_job "issue-$n" "$base")
  comments=$(owner_comments_md "$n")

  {
    printf '# Issue #%s: %s\n\n' "$n" "$title"
    printf 'You are on a fresh branch `%s`, made from `%s`.\n\n## Issue body\n\n' "$branch" "$AGENT_DEFAULT_BRANCH"
    jq -r '.body // "(no body)"' <<<"$issue"
    if [[ -n $comments ]]; then printf '\n\n## Comments from @%s (oldest first)\n\n%s\n' "$AGENT_OWNER" "$comments"; fi
    printf '\n\n## Clarification file\n\nIf the issue is too ambiguous to implement, write your questions to `%s` and make no commits.\n\n---\n\n' "$NEEDS_INFO"
    cat "$PROMPTS/prompt-issue.md"
  } >"$job/prompt.md"

  run_job "$job" "$branch" "$base"

  label_rm "$n" agent:working

  if [[ -n $JOB_NEEDS ]] && ((JOB_COMMITS == 0)); then
    printf 'I need some answers before I can start. Reply here, then re-add `agent`.\n\n%s\n' "$JOB_NEEDS" | comment "$n"
    label_add "$n" agent:needs-info
    log "#$n: needs info"
    return
  fi

  if ((JOB_COMMITS == 0)); then
    printf '**The agent made no commits** (`%s`, exit %s). Re-add `agent` to retry.\n\n%s\n' \
      "$JOB_SUBTYPE" "$JOB_RC" "${JOB_RESULT:-(no summary)}" | comment "$n"
    label_add "$n" agent:failed
    log "#$n: failed, no commits"
    return
  fi

  if ! push "$JOB_HEAD" "$branch" --force; then
    printf '**Pushing `%s` failed.** %s Re-add `agent` to retry.\n' "$branch" "$PUSH_HINT" | comment "$n"
    label_add "$n" agent:failed
    log "#$n: push failed"
    return
  fi

  if job_failed; then
    printf '**Partial work on branch `%s`, no PR** (`%s`, exit %s). Re-add `agent` to retry.\n\n%s\n' \
      "$branch" "$JOB_SUBTYPE" "$JOB_RC" "${JOB_RESULT:-(no summary)}" | comment "$n"
    label_add "$n" agent:failed
    log "#$n: failed, partial work pushed"
    return
  fi

  local body_file=$job/pr-body.md footer existing pr_title="$title (#$n)"
  if [[ $AGENT_AUTO_MERGE == true ]]; then
    footer="**Approve** and I'll squash-merge on my next poll. **Request changes** (inline comments welcome) and I'll revise. To ask for another pass without a review, add the \`agent\` label to this PR."
  else
    footer="**Request changes** (inline comments welcome) and I'll revise; merge it yourself when happy. To ask for another pass without a review, add the \`agent\` label to this PR."
  fi
  {
    printf '%s\n' "${JOB_RESULT:-(no summary)}" | head -c $((MAX_BODY - 2000))
    printf '\n\nCloses #%s\n\n---\n\n_Opened by the Helix Reborn agent._ %s\n' "$n" "$footer"
  } >"$body_file"

  existing=$(api "repos/$R/pulls?state=open&head=$REPO_OWNER:$branch" -q '.[0].number // empty')
  if [[ -n $existing ]]; then
    api -X PATCH "repos/$R/pulls/$existing" -f title="$pr_title" -F body=@"$body_file" >/dev/null
    log "#$n: updated PR #$existing"
  else
    existing=$(api -X POST "repos/$R/pulls" -f title="$pr_title" -f head="$branch" -f base="$AGENT_DEFAULT_BRANCH" \
      -F body=@"$body_file" -q .number)
    log "#$n: opened PR #$existing"
  fi
  label_add "$n" agent:review
}

# ---------------------------------------------------------------------------------------------

main() {
  exec 9>"$LOCK"
  if ! flock -n 9; then
    log "another tick is still running"
    exit 0
  fi
  mkdir -p "$GH_CONFIG_DIR"
  RAN_JOB=0

  sync_clone
  housekeeping
  if [[ $AGENT_AUTO_MERGE == true ]]; then
    merge_approved
    sync_clone
  fi
  revise_one
  [[ $RAN_JOB == 1 ]] && exit 0
  pick_issue
  [[ $RAN_JOB == 1 ]] || log "nothing to do"
}

main "$@"
