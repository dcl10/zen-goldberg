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
: "${AGENT_MAX_TURNS:?}" "${AGENT_JOB_TIMEOUT:?}" "${AGENT_AUTO_MERGE:?}" "${AGENT_MIN_QUOTA_TOKENS:?}" "${GH_TOKEN:?}"

R=$AGENT_REPO
REPO_OWNER=${R%%/*}
STATE_DIR=${STATE_DIRECTORY:-/var/lib/agent-ctl}
CLONE=$STATE_DIR/repo.git
JOBS=/srv/agent-work/jobs
OUT_DIR=/srv/agent-work/out
NEEDS_INFO=/srv/agent-work/scratch/NEEDS_INFO.md
LOG_DIR=/var/log/agent
PROMPTS=/opt/agent
LOCK=${RUNTIME_DIRECTORY:-/run/agent-poll}/lock
MAX_BODY=60000
# After a run is refused for quota (HTTP 429, or the pre-flight check), no model jobs until this
# file's epoch time; the issue or PR gets agent:rate-limited. When the pause ends, a 1-token
# check looks at the quota again: the retry starts once enough is back, and otherwise the
# pause is renewed without touching the issue. So the backoff is how often to look.
RATE_LIMIT_FILE=$STATE_DIR/rate-limited-until
RATE_LIMIT_BACKOFF=${AGENT_RATE_LIMIT_BACKOFF:-900}
# run-claude.sh's exit code when its pre-flight check finds too little daily quota left.
QUOTA_LOW_EXIT=75
# Anthropic model ID => DO model ID (Terraform's model_overrides). Claude Code's per-message
# events name the Anthropic ID, its final result the DO ID; usage is keyed by the DO ID.
MODEL_IDS=${AGENT_MODEL_IDS:-'{}'}
jq -e 'type == "object" and all(.[]; type == "string")' <<<"$MODEL_IDS" >/dev/null 2>&1 || MODEL_IDS='{}'
# Marks the bot's rate-limit comments, which aren't "activity" for [NEW] feedback on a PR.
RATE_LIMIT_MARK='<!-- agent:rate-limited -->'

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
    jq -r --arg b "$AGENT_BOT" --arg mark "$RATE_LIMIT_MARK" \
      'map(select(.user.login == $b and ((.body // "") | contains($mark) | not)) | .created_at) | max // ""')
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
  for f in events.jsonl needs-info.md changes.bundle summary.jsonl; do
    : >"$job/$f"
    chmod 0660 "$job/$f"
  done
  printf '%s\n' "$job"
}

# run_job <job-dir> <branch> <base-sha>. Sets:
#   JOB_RC, JOB_TIMED_OUT, JOB_QUOTA_LOW (+ JOB_QUOTA_LEFT): how run-claude.sh ended
#   JOB_SUBTYPE, JOB_IS_ERROR, JOB_RESULT: from Claude's final result event; without one,
#     JOB_SUBTYPE is timeout, quota_low or no_result and JOB_RESULT is empty
#   JOB_LAST_TEXT: Claude's last text message, for runs that ended without a result
#   JOB_SUMMARY: the final message a run that hit --max-turns wrote when resumed for it (its
#     usage is included in JOB_USAGE)
#   JOB_RETRIES, JOB_RL_RETRIES, JOB_STUCK_429: API retries, those for 429s, and whether
#     the run was killed while retrying a 429
#   JOB_USAGE, JOB_USAGE_PARTIAL: per-model token usage (see "Token usage"); partial when it
#     had to be added up from the events because the run never finished
#   JOB_NEEDS, JOB_COMMITS, JOB_HEAD: clarification questions and returned commits
# Everything read back from the job dir was written by `agent`: treat it as untrusted data.
run_job() {
  local job=$1 branch=$2 base=$3 id summary
  id=$(basename "$job")
  chmod 0640 "$job/prompt.md"
  log "job $id: $AGENT_MODEL on $branch from ${base:0:12}"

  JOB_RC=0
  timeout --kill-after=2m "$AGENT_JOB_TIMEOUT" \
    sudo -n -u agent /opt/agent/run-claude.sh "$job" "$AGENT_MODEL" "$AGENT_MAX_TURNS" "$branch" "$AGENT_MIN_QUOTA_TOKENS" \
    >"$LOG_DIR/$id.log" 2>&1 || JOB_RC=$?

  JOB_TIMED_OUT=false JOB_QUOTA_LOW=false JOB_QUOTA_LEFT=
  [[ $JOB_RC -eq 124 || $JOB_RC -eq 137 ]] && JOB_TIMED_OUT=true
  if [[ $JOB_RC -eq $QUOTA_LOW_EXIT ]]; then
    JOB_QUOTA_LOW=true
    JOB_QUOTA_LEFT=$(sed -n 's/^run-claude: quota \([0-9]\{1,12\}\) tokens left.*/\1/p' "$LOG_DIR/$id.log" | tail -n 1)
  fi

  cp "$job/events.jsonl" "$LOG_DIR/$id.jsonl"
  summary=$(head -c 268435456 "$job/events.jsonl" | jq -n -R -c --argjson ids "$MODEL_IDS" "$USAGE_JQ run_summary(\$ids)" 2>/dev/null) ||
    summary='{}'
  jq -e 'type == "object"' <<<"$summary" >/dev/null 2>&1 || summary='{}'
  log "job $id: exit $JOB_RC $(jq -c '{final, subtype, is_error, num_turns, duration_ms, retries, rate_limit_retries, usage}' <<<"$summary")"

  if [[ $(jq -r '.final == true' <<<"$summary") == true ]]; then
    JOB_SUBTYPE=$(jq -r '.subtype // "unknown" | tostring' <<<"$summary")
    JOB_IS_ERROR=$(jq -r 'if .is_error == false then "false" else "true" end' <<<"$summary")
    JOB_RESULT=$(jq -r '.result // "" | tostring' <<<"$summary")
    JOB_USAGE_PARTIAL=false
  else
    if [[ $JOB_TIMED_OUT == true ]]; then JOB_SUBTYPE=timeout
    elif [[ $JOB_QUOTA_LOW == true ]]; then JOB_SUBTYPE=quota_low
    else JOB_SUBTYPE=no_result; fi
    JOB_IS_ERROR=true JOB_RESULT= JOB_USAGE_PARTIAL=true
    [[ $JOB_QUOTA_LOW == true ]] && JOB_USAGE_PARTIAL=false
    log "job $id: no result event (see $LOG_DIR/$id.log and $id.jsonl)"
  fi
  JOB_USAGE=$(jq -c '.usage // {}' <<<"$summary")
  JOB_LAST_TEXT=$(jq -r '.last_text // "" | tostring' <<<"$summary")
  JOB_RETRIES=$(jq -r '.retries // 0' <<<"$summary")
  JOB_RL_RETRIES=$(jq -r '.rate_limit_retries // 0' <<<"$summary")
  JOB_STUCK_429=$(jq -r '.stuck_on_429 == true' <<<"$summary")

  JOB_SUMMARY=
  if [[ -s $job/summary.jsonl ]]; then
    cp "$job/summary.jsonl" "$LOG_DIR/$id.summary.jsonl"
    summary=$(head -c 67108864 "$job/summary.jsonl" | jq -n -R -c --argjson ids "$MODEL_IDS" "$USAGE_JQ run_summary(\$ids)" 2>/dev/null) ||
      summary='{}'
    jq -e 'type == "object"' <<<"$summary" >/dev/null 2>&1 || summary='{}'
    log "job $id: final message after the turn limit: $(jq -c '{subtype, is_error, num_turns, usage}' <<<"$summary")"
    JOB_USAGE=$(jq -c --argjson b "$(jq -c '.usage // {}' <<<"$summary")" "$USAGE_JQ add_usage(.; \$b)" <<<"$JOB_USAGE")
    if [[ $(jq -r '.final == true and .is_error == false' <<<"$summary") == true ]]; then
      JOB_SUMMARY=$(jq -r '.result // "" | tostring' <<<"$summary")
    fi
  fi

  JOB_NEEDS=$(head -c "$MAX_BODY" "$job/needs-info.md")
  # The usage section's markers are ours alone: model text carrying them could hijack the
  # section on the next revision (whatever the target repo's CLAUDE.md tells the model).
  JOB_RESULT=${JOB_RESULT//"$USAGE_START"/} JOB_RESULT=${JOB_RESULT//"$USAGE_END"/}
  JOB_NEEDS=${JOB_NEEDS//"$USAGE_START"/} JOB_NEEDS=${JOB_NEEDS//"$USAGE_END"/}
  JOB_LAST_TEXT=${JOB_LAST_TEXT//"$USAGE_START"/} JOB_LAST_TEXT=${JOB_LAST_TEXT//"$USAGE_END"/}
  JOB_SUMMARY=${JOB_SUMMARY//"$USAGE_START"/} JOB_SUMMARY=${JOB_SUMMARY//"$USAGE_END"/}

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

# The run never started or stopped for quota: the pre-flight check found too little left; or
# Claude Code ran out of retries on a 429 and ended with a result like "API Error: Request
# rejected (429) · Rate limit exceeded: tokens_per_day."; or the job timeout killed it while
# it was still retrying a 429.
job_rate_limited() {
  local first=${JOB_RESULT%%$'\n'*}
  [[ $JOB_QUOTA_LOW == true ]] && return 0
  job_failed || return 1
  [[ $first == "API Error:"* && $first =~ (\(429\)|[Rr]ate\ limit) ]] || [[ $JOB_STUCK_429 == true ]]
}

# How a failed run ended, for comments: "timed out after 45m" or "`subtype`, exit N", plus
# its API retries.
job_how() {
  if [[ $JOB_TIMED_OUT == true ]]; then
    printf 'timed out after %s' "$AGENT_JOB_TIMEOUT"
  elif [[ $JOB_SUBTYPE == error_max_turns ]]; then
    printf 'hit the %s-turn limit' "$AGENT_MAX_TURNS"
  else
    printf '`%s`, exit %s' "$JOB_SUBTYPE" "$JOB_RC"
  fi
  if ((JOB_RETRIES > 0)); then
    printf '; %s API retries, %s of them for rate limits' "$JOB_RETRIES" "$JOB_RL_RETRIES"
  fi
}

# What the run said: its final summary, or else its last message before it stopped.
job_summary_md() {
  if [[ -n $JOB_RESULT ]]; then
    printf '%s\n' "$JOB_RESULT"
  elif [[ -n $JOB_SUMMARY ]]; then
    printf '%s\n' "$JOB_SUMMARY"
  elif [[ -n $JOB_LAST_TEXT ]]; then
    printf 'It stopped before writing a summary. Its last message:\n\n'
    sed 's/^/> /' <<<"$JOB_LAST_TEXT"
  else
    printf '(no summary)\n'
  fi
}

# True while a rate-limit pause is running.
rate_limited() {
  local resume
  [[ -s $RATE_LIMIT_FILE ]] || return 1
  resume=$(<"$RATE_LIMIT_FILE")
  [[ $resume =~ ^[0-9]+$ ]] && (($(date +%s) < resume))
}

# pause_jobs: no model jobs for RATE_LIMIT_BACKOFF; prints when the pause ends.
pause_jobs() {
  local resume
  resume=$(($(date +%s) + RATE_LIMIT_BACKOFF))
  printf '%s\n' "$resume" >"$RATE_LIMIT_FILE"
  date -u -d "@$resume" '+%Y-%m-%d %H:%M UTC'
}

# quota_ok <issue-or-pr>: run-claude.sh's pre-flight check on its own. When it finds too little
# quota for a rate-limited retry, renew the pause and fail, before any label changes, so a
# waiting issue's timeline isn't filled with label churn every few minutes.
quota_ok() {
  local n=$1 rc=0 out when
  out=$(sudo -n -u agent /opt/agent/run-claude.sh --quota-check "$AGENT_MODEL" "$AGENT_MIN_QUOTA_TOKENS" 2>&1) || rc=$?
  [[ -z $out ]] || log "#$n: ${out#run-claude: }"
  ((rc == QUOTA_LOW_EXIT)) || return 0
  when=$(pause_jobs)
  log "#$n: retry waits for quota; no model jobs until $when"
  return 1
}

# rate_limit_requeue <issue-or-pr> <already-rate-limited> [<branch>]: pause model jobs, label
# <n> for a retry when the pause ends, and comment. A retry the quota check stopped before it
# began gets no comment (the first one already said it's waiting); one that ran does, with
# what it got done.
rate_limit_requeue() {
  local n=$1 already=$2 branch=${3:-} when
  when=$(pause_jobs)
  label_add "$n" agent:rate-limited
  log "#$n: rate limited; no model jobs until $when"
  [[ $already == true && $JOB_QUOTA_LOW == true ]] && return
  {
    printf '%s\n' "$RATE_LIMIT_MARK"
    if [[ $JOB_QUOTA_LOW == true ]]; then
      printf '**Not started: too little model quota left today** (%s tokens; a run needs about %s). ' \
        "$(jq -rn "$USAGE_JQ ${JOB_QUOTA_LEFT:-0} | commas")" "$(jq -rn "$USAGE_JQ $AGENT_MIN_QUOTA_TOKENS | commas")"
    elif [[ $already == true ]]; then
      printf '**Rate-limited again** (%s). ' "$(job_how)"
    else
      printf '**The model provider rate-limited this run** (%s). ' "$(job_how)"
    fi
    if [[ -n $branch ]] && ((JOB_COMMITS > 0)); then
      printf 'Its %s commit(s) are pushed to `%s`, and the next run carries on from them. ' "$JOB_COMMITS" "$branch"
    fi
    printf 'I'\''ll check the quota every %s minutes (first at %s) and carry on once about %s tokens are free. ' \
      "$((RATE_LIMIT_BACKOFF / 60))" "$when" "$(jq -rn "$USAGE_JQ $AGENT_MIN_QUOTA_TOKENS | commas")"
    printf 'Remove `agent:rate-limited` to cancel.\n\n'
    [[ $JOB_QUOTA_LOW == true ]] || job_summary_md
  } | comment_run "$n"
}

# push <sha> <branch> [--force]
push() {
  git -C "$CLONE" push -q ${3:+"$3"} origin "$1:refs/heads/$2"
}

PUSH_HINT="The push was rejected. If the change touches .github/workflows, the bot's token can't push it (no workflow scope)."

# ---------------------------------------------------------------------------------------------
# Token usage
# ---------------------------------------------------------------------------------------------
# Usage JSON everywhere below is {"<model>": {input, output, cache_read, cache_write}}.
# It comes from .modelUsage in Claude's final result event, not the top-level .usage, which
# leaves out background models. A run killed before its result (job timeout) has no
# .modelUsage, so its usage is added up from the per-message usage in its assistant events
# instead; that misses Claude Code's background calls, so it's marked partial.
# No cost is shown: total_cost_usd uses Anthropic list prices, not DO's.

USAGE_START='<!-- agent-usage:start -->'
USAGE_END='<!-- agent-usage:end -->'

# shellcheck disable=SC2016
USAGE_JQ='
  def tokens: if type == "number" and . >= 0 then floor else 0 end;
  def model_key: tostring | gsub("[^A-Za-z0-9._-]"; "") | .[:64] | if . == "" then "unknown" else . end;
  # Add token counts $t ({input, output, cache_read, cache_write}) to model $m.
  def add_tokens($m; $t):
    .[$m] = ((.[$m] // {}) as $o | {
      input: (($o.input // 0) + $t.input),
      output: (($o.output // 0) + $t.output),
      cache_read: (($o.cache_read // 0) + $t.cache_read),
      cache_write: (($o.cache_write // 0) + $t.cache_write)});
  # Claude Code'"'"'s final result event (written by `agent`, so untrusted) -> usage JSON.
  def usage_of:
    if type == "object" and (.modelUsage | type) == "object" then
      reduce (.modelUsage | to_entries | .[:20][]) as $e ({};
        ($e.value | if type == "object" then . else {} end) as $v
        | add_tokens($e.key | model_key; {
            input: ($v.inputTokens | tokens), output: ($v.outputTokens | tokens),
            cache_read: ($v.cacheReadInputTokens | tokens), cache_write: ($v.cacheCreationInputTokens | tokens)}))
    else {} end;
  # Array of events -> usage JSON from the assistant messages. One API response can appear as
  # several events (one per content block) with the same id and usage, so keep one per id.
  # $ids maps Anthropic model IDs to DO ones.
  def stream_usage($ids):
    reduce (.[] | select(.type == "assistant") | .message | objects | select(.id != null)) as $m
      ({}; .[$m.id | tostring] = $m)
    | reduce (.[]) as $m ({};
        ($m.model | tostring | ($ids[.] // .) | model_key) as $k
        | ($m.usage | if type == "object" then . else {} end) as $u
        | add_tokens($k; {
            input: ($u.input_tokens | tokens), output: ($u.output_tokens | tokens),
            cache_read: ($u.cache_read_input_tokens | tokens), cache_write: ($u.cache_creation_input_tokens | tokens)}))
    | to_entries | .[:20] | from_entries;
  # stream-json lines on stdin (jq -n -R) -> what run_job needs from them. Unparsable lines (a
  # run killed mid-write) are skipped.
  def run_summary($ids):
    [inputs | fromjson? | objects] as $ev
    | ($ev | map(select(.type == "result")) | last) as $r
    | ($ev | map(select(.type == "system" and .subtype == "api_retry"))) as $retries
    | ([$ev | to_entries[] | select(.value.type == "assistant") | .key] | last // -1) as $last_assistant
    | ([$ev | to_entries[] | select(.value.type == "system" and .value.subtype == "api_retry"
          and .value.error_status == 429) | .key] | last // -1) as $last_429
    | {
        final: ($r != null),
        subtype: $r.subtype,
        is_error: $r.is_error,
        result: $r.result,
        num_turns: $r.num_turns,
        duration_ms: $r.duration_ms,
        retries: ($retries | length),
        rate_limit_retries: ($retries | map(select(.error_status == 429)) | length),
        stuck_on_429: ($r == null and $last_429 > $last_assistant),
        last_text: ([$ev[] | select(.type == "assistant") | .message.content? | arrays | .[]
          | objects | select(.type == "text") | .text | strings] | last // "" | .[:4000]),
        usage: (if $r != null then ($r | usage_of) else ($ev | stream_usage($ids)) end)
      };
  def add_usage($a; $b):
    reduce ($b | to_entries[]) as $e ($a;
      .[$e.key] = ((.[$e.key] // {}) as $o | $e.value | with_entries(.value += ($o[.key] // 0))));
  def commas: if . < 1000 then tostring else ((. / 1000 | floor) | commas) + "," + ("00" + (. % 1000 | tostring))[-3:] end;
  def usage_row($label): "| \($label) | \(.input | commas) | \(.output | commas) | \(.cache_read | commas) | \(.cache_write | commas) |";
  def usage_table:
    if length == 0 then "_No usage reported._" else
      ["| Model | Input | Output | Cache read | Cache write |", "|---|--:|--:|--:|--:|"]
      + [to_entries | sort_by(.key)[] | .key as $k | .value | usage_row("`\($k)`")]
      + (if length > 1 then [reduce .[] as $u ({input: 0, output: 0, cache_read: 0, cache_write: 0};
          with_entries(.value += $u[.key])) | usage_row("**Total**")] else [] end)
      | join("\n")
    end;
'

# The PR body and every comment after a run are built here, never by the model, so the
# usage is always added; the model's text is cut first so the usage always fits.
USAGE_NOTE="_Counted by the poll script from Claude Code's result, not reported by the model._"

USAGE_PARTIAL_NOTE="_Counted by the poll script from Claude Code's events up to where the run stopped, not reported by the model. Its background calls (\`haiku\`) aren't in them, so the real usage is a little higher._"

# This run's usage as markdown, for comments.
run_usage_md() {
  if [[ $JOB_QUOTA_LOW == true ]]; then
    printf '\n_No model tokens used: the run didn'\''t start._\n'
    return
  fi
  printf '\n**Token usage, this run**\n\n'
  jq -r "$USAGE_JQ usage_table" <<<"$JOB_USAGE"
  if [[ $JOB_USAGE_PARTIAL == true ]]; then
    printf '\n%s\n' "$USAGE_PARTIAL_NOTE"
  else
    printf '\n%s\n' "$USAGE_NOTE"
  fi
}

# comment_run <number>: message on stdin, then this run's token usage.
comment_run() {
  { head -c $((MAX_BODY - 8000)); printf '\n'; run_usage_md; } | comment "$1"
}

# issue_usage_add <issue>: add this run's usage to issue <issue>'s running total, save it,
# and set ISSUE_USAGE to {runs, total, latest}. Totals are per issue, not per PR, so every
# run counts, including failed ones before a PR exists. Branch agent/issue-N is 1:1 with
# its PR, so a PR's total is its issue's.
issue_usage_add() {
  local f=$OUT_DIR/issue-$1-usage.json prev='{}'
  if [[ -s $f ]]; then
    prev=$(jq -c 'if type == "object" and (.total | type) == "object" then . else {} end' "$f" 2>/dev/null) || prev='{}'
  fi
  ISSUE_USAGE=$(jq -c --argjson run "$JOB_USAGE" \
    "$USAGE_JQ"' {runs: ((.runs // 0) + 1), total: add_usage(.total // {}; $run), latest: $run}' <<<"$prev")
  if ! { printf '%s\n' "$ISSUE_USAGE" >"$f.tmp" && mv -f "$f.tmp" "$f"; } 2>/dev/null; then
    log "#$1: couldn't save token usage to $f"
  fi
}

# The PR body's usage section (between markers, so revisions can replace it), from ISSUE_USAGE.
pr_usage_section() {
  printf '%s\n' "$USAGE_START"
  jq -r "$USAGE_JQ"' "### Token usage\n\n" + (if .runs > 1
      then "**Total, \(.runs) runs**\n\n\(.total | usage_table)\n\n**Latest run**\n\n\(.latest | usage_table)"
      else .total | usage_table end)' <<<"$ISSUE_USAGE"
  printf '\n%s\n%s\n' "$USAGE_NOTE" "$USAGE_END"
}

# pr_body_update_usage <pr> <scratch-prefix>: replace the usage section in PR <pr>'s body
# (or insert it before `Closes #n`, or at the end) and PATCH the PR. Keeps any other edits.
pr_body_update_usage() {
  local n=$1 tmp=$2
  # Called with errexit off (`|| log`), so stop by hand rather than PATCH a body we never read.
  api "repos/$R/pulls/$n" -q '.body // ""' >"$tmp.old" || return 1
  pr_usage_section >"$tmp.usage" || return 1
  awk -v sec="$tmp.usage" -v s="$USAGE_START" -v e="$USAGE_END" -v marked="$(tr -d '\r' <"$tmp.old" | grep -c -x -F -- "$USAGE_START" || true)" '
    function put(l) { while ((getline l < sec) > 0) print l; close(sec); done = 1 }
    { line = $0; sub(/\r$/, "", line) }
    skip { if (line == e) skip = 0; next }
    !done && marked > 0 && line == s { put(); skip = 1; next }
    !done && marked == 0 && line ~ /^Closes #[0-9]+$/ { put(); print "" }
    { print }
    END { if (!done) { print ""; put() } }
  ' "$tmp.old" | head -c "$MAX_BODY" >"$tmp.new"
  api -X PATCH "repos/$R/pulls/$n" -F body=@"$tmp.new" >/dev/null
}

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
    if [[ -z $reason ]] && has_label "$pr" agent:rate-limited; then
      labeler=$(last_labeler "$n" agent:rate-limited)
      if [[ $labeler == "$AGENT_BOT" ]]; then
        reason="a rate-limit retry"
      else
        log "PR #$n: agent:rate-limited added by '$labeler', not $AGENT_BOT; ignoring it"
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
  local pr=$1 n branch issue sha title last job prompt feedback was_limited=false
  n=$(jq -r .number <<<"$pr")
  branch=$(jq -r .head.ref <<<"$pr")
  sha=$(jq -r .head.sha <<<"$pr")
  title=$(jq -r .title <<<"$pr")
  issue=${branch#agent/issue-}
  has_label "$pr" agent:rate-limited && was_limited=true
  if [[ $was_limited == true ]] && ! quota_ok "$n"; then return; fi

  label_rm "$n" agent
  label_rm "$n" agent:failed
  label_rm "$n" agent:rate-limited
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

  local pushed=true failed=false stopped=false body
  if ((JOB_COMMITS > 0)); then
    push "$JOB_HEAD" "$branch" || pushed=false
  fi
  # A run that stopped early (turn limit, timeout, an error) but pushed commits may well have
  # done the job: that's for the owner to judge from the commits, so it isn't marked failed.
  if [[ $pushed == false ]] || { job_failed && ((JOB_COMMITS == 0)); }; then
    failed=true
  elif job_failed; then
    stopped=true
  fi

  # Every run counts toward the PR's total, failed ones included; one the pre-flight check
  # stopped never started.
  if [[ $JOB_QUOTA_LOW == false ]]; then
    issue_usage_add "$issue"
    pr_body_update_usage "$n" "$job/pr-body" || pr_body_update_usage "$n" "$job/pr-body" ||
      log "PR #$n: couldn't update the token usage in the PR body (the comment below still has this run's)"
  fi

  # Any partial commits are already pushed, so the retry carries on from them.
  if job_rate_limited && [[ $pushed == true ]]; then
    rate_limit_requeue "$n" "$was_limited" "$branch"
    label_rm "$n" agent:working
    return
  fi

  if [[ -n $JOB_NEEDS ]]; then
    body=$JOB_NEEDS
  else
    body=$(job_summary_md)
  fi
  {
    if [[ $failed == true ]]; then
      printf '**This revision run failed** (%s). Re-add `agent` to retry.\n\n' "$(job_how)"
      [[ $pushed == false ]] && printf '%s\n\n' "$PUSH_HINT"
    elif [[ $stopped == true ]]; then
      printf '**This revision stopped before it finished** (%s). Its %s commit(s) are pushed: check whether ' "$(job_how)" "$JOB_COMMITS"
      printf 'they cover the feedback. To have me carry on, request changes again or add `agent`.\n\n'
    fi
    printf '%s\n' "$body"
  } | comment_run "$n"

  [[ $failed == true ]] && label_add "$n" agent:failed
  label_rm "$n" agent:working
  log "PR #$n: revision done (failed=$failed, stopped=$stopped, commits=$JOB_COMMITS)"
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
  local issue n labeler blockers trigger who
  while read -r issue; do
    [[ -n $issue ]] || continue
    n=$(jq -r .number <<<"$issue")
    # Queued by the owner (agent), or by the bot itself for a rate-limit retry.
    if has_label "$issue" agent; then
      trigger=agent who=$AGENT_OWNER
    else
      trigger=agent:rate-limited who=$AGENT_BOT
    fi
    labeler=$(last_labeler "$n" "$trigger")
    if [[ $labeler != "$who" ]]; then
      log "#$n: skipped, $trigger label last added by '$labeler', not $who"
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
  done < <(api_all "repos/$R/issues?state=open&creator=$AGENT_OWNER&sort=created&direction=asc&per_page=100" |
    jq -c --arg o "$AGENT_OWNER" '.[] | select((.pull_request | not) and .user.login == $o
      and any(.labels[]; .name == "agent" or .name == "agent:rate-limited"))')
}

do_issue() {
  local issue=$1 n title branch base main_sha job comments was_limited=false resume_file resume_sha=
  n=$(jq -r .number <<<"$issue")
  title=$(jq -r .title <<<"$issue")
  branch=agent/issue-$n
  resume_file=$STATE_DIR/issue-$n-resume
  has_label "$issue" agent:rate-limited && was_limited=true
  if [[ $was_limited == true ]] && ! quota_ok "$n"; then return; fi
  log "#$n: starting ($title)"

  label_rm "$n" agent
  label_rm "$n" agent:failed
  label_rm "$n" agent:needs-info
  label_rm "$n" agent:rate-limited
  label_add "$n" agent:working

  # A rate-limit retry carries on from the partial work the cut-short attempt pushed, if the
  # branch still points at it. Any other start (the owner adding `agent`) begins again from
  # the default branch.
  if [[ $was_limited == true && -s $resume_file ]]; then
    resume_sha=$(<"$resume_file")
    [[ $(git -C "$CLONE" rev-parse -q --verify "refs/remotes/origin/$branch" || true) == "$resume_sha" ]] || resume_sha=
  fi
  rm -f "$resume_file"

  main_sha=$(git -C "$CLONE" rev-parse "refs/remotes/origin/$AGENT_DEFAULT_BRANCH")
  base=${resume_sha:-$main_sha}
  job=$(new_job "issue-$n" "$base")
  comments=$(owner_comments_md "$n")

  {
    printf '# Issue #%s: %s\n\n' "$n" "$title"
    if [[ -n $resume_sha ]]; then
      printf 'You are on branch `%s`, which already holds partial work on this issue from an earlier ' "$branch"
      printf 'attempt that the model rate limit cut short. Its commits since `%s` (%s):\n\n' "$AGENT_DEFAULT_BRANCH" "${main_sha:0:12}"
      git -C "$CLONE" log -n 50 --oneline --no-decorate "$main_sha..$resume_sha" | sed 's/^/    /'
      printf '\nCheck what is already done (`git diff %s..HEAD --stat`, then the parts you need) ' "${main_sha:0:12}"
      printf 'and carry on from there; don'\''t redo finished work. Uncommitted work from that attempt is lost.\n\n## Issue body\n\n'
    else
      printf 'You are on a fresh branch `%s`, made from `%s`.\n\n## Issue body\n\n' "$branch" "$AGENT_DEFAULT_BRANCH"
    fi
    jq -r '.body // "(no body)"' <<<"$issue"
    if [[ -n $comments ]]; then printf '\n\n## Comments from @%s (oldest first)\n\n%s\n' "$AGENT_OWNER" "$comments"; fi
    printf '\n\n## Clarification file\n\nIf the issue is too ambiguous to implement, write your questions to `%s` and make no commits.\n\n---\n\n' "$NEEDS_INFO"
    cat "$PROMPTS/prompt-issue.md"
  } >"$job/prompt.md"

  run_job "$job" "$branch" "$base"
  # Before any early return: failed runs count toward the issue's total. A run the pre-flight
  # check stopped never started, so it doesn't.
  [[ $JOB_QUOTA_LOW == true ]] || issue_usage_add "$n"

  label_rm "$n" agent:working

  # Rate limited: push any partial commits and note where they reached, so the retry carries
  # on from them instead of redoing the work from the default branch.
  if job_rate_limited; then
    local pushed_to=
    if ((JOB_COMMITS > 0)); then
      if push "$JOB_HEAD" "$branch" --force; then
        printf '%s\n' "$JOB_HEAD" >"$resume_file"
        pushed_to=$branch
        log "#$n: partial work pushed to $branch; the retry carries on from it"
      else
        log "#$n: pushing partial work failed; the retry starts from ${resume_sha:-the default branch}"
        [[ -z $resume_sha ]] || printf '%s\n' "$resume_sha" >"$resume_file"
      fi
    elif [[ -n $resume_sha ]]; then
      printf '%s\n' "$resume_sha" >"$resume_file"
    fi
    rate_limit_requeue "$n" "$was_limited" "$pushed_to"
    return
  fi

  if [[ -n $JOB_NEEDS ]] && ((JOB_COMMITS == 0)); then
    {
      printf 'I need some answers before I can start. Reply here, then re-add `agent`.\n\n%s\n' "$JOB_NEEDS"
    } | comment_run "$n"
    label_add "$n" agent:needs-info
    log "#$n: needs info"
    return
  fi

  # A resumed run adds nothing new when the cut-short attempt had already finished the work;
  # the branch's earlier commits still go on to the push and PR below.
  if ((JOB_COMMITS == 0)) && [[ -z $resume_sha ]]; then
    {
      printf '**The agent made no commits** (%s). Re-add `agent` to retry.\n\n' "$(job_how)"
      job_summary_md
    } | comment_run "$n"
    label_add "$n" agent:failed
    log "#$n: failed, no commits"
    return
  fi

  if ! push "$JOB_HEAD" "$branch" --force; then
    {
      printf '**Pushing `%s` failed.** %s Re-add `agent` to retry.\n' "$branch" "$PUSH_HINT"
    } | comment_run "$n"
    label_add "$n" agent:failed
    log "#$n: push failed"
    return
  fi

  # A run that stopped early (turn limit, timeout, an error) may still have finished the work.
  # The owner judges that from the commits, so they go up as a draft PR instead of failing the
  # issue. Drafts are left alone (bot_prs) until the owner marks them ready for review.
  local incomplete=false body_file=$job/pr-body.md footer existing pr_title="$title (#$n)" text
  job_failed && incomplete=true
  if [[ $AGENT_AUTO_MERGE == true ]]; then
    footer="**Approve** and I'll squash-merge on my next poll. **Request changes** (inline comments welcome) and I'll revise. To ask for another pass without a review, add the \`agent\` label to this PR."
  else
    footer="**Request changes** (inline comments welcome) and I'll revise; merge it yourself when happy. To ask for another pass without a review, add the \`agent\` label to this PR."
  fi
  if [[ $incomplete == true ]]; then
    text=$(job_summary_md)
  else
    text=${JOB_RESULT:-(no summary)}
  fi
  {
    if [[ $incomplete == true ]]; then
      printf '> [!WARNING]\n> **Draft: this run stopped before it finished** (%s). Check whether the work is complete. ' "$(job_how)"
      printf 'I leave drafts alone, so mark it **ready for review** first, then use the options at the bottom.\n\n'
    fi
    printf '%s\n' "${text:0:$((MAX_BODY - 10000))}"
    if [[ $incomplete == true ]]; then
      printf '\n**Commits on this branch**\n\n'
      git -C "$CLONE" log -n 50 --format='- %h %s' "$main_sha..$JOB_HEAD"
    fi
    printf '\n'
    pr_usage_section
    printf '\nCloses #%s\n\n---\n\n_Opened by the Helix Reborn agent._ %s\n' "$n" "$footer"
  } >"$body_file"

  existing=$(api "repos/$R/pulls?state=open&head=$REPO_OWNER:$branch" -q '.[0].number // empty')
  if [[ -n $existing ]]; then
    api -X PATCH "repos/$R/pulls/$existing" -f title="$pr_title" -F body=@"$body_file" >/dev/null
    log "#$n: updated PR #$existing (incomplete=$incomplete)"
  else
    existing=$(api -X POST "repos/$R/pulls" -f title="$pr_title" -f head="$branch" -f base="$AGENT_DEFAULT_BRANCH" \
      -F draft="$incomplete" -F body=@"$body_file" -q .number)
    if [[ $incomplete == true ]]; then log "#$n: opened draft PR #$existing (run stopped early)"; else log "#$n: opened PR #$existing"; fi
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
  if rate_limited; then
    log "rate limited until $(date -u -d "@$(<"$RATE_LIMIT_FILE")" '+%Y-%m-%d %H:%M UTC'); no model jobs this tick"
    exit 0
  fi
  revise_one
  [[ $RAN_JOB == 1 ]] && exit 0
  pick_issue
  [[ $RAN_JOB == 1 ]] || log "nothing to do"
}

main "$@"
