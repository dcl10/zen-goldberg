# zen-goldberg

Infrastructure for an unattended Claude Code bot that works on
[Helix Reborn](https://github.com/dcl10/helix-reborn). It runs on a DigitalOcean Droplet and uses
DigitalOcean serverless inference (Sonnet 5, with Haiku 5.5 for background tasks), not a Claude
subscription.

The flow:

1. Dan writes issues (planned with Opus on his own machine) and labels them `agent`.
2. Every few minutes the bot picks up the oldest unblocked one, runs Claude Code on it, and opens a PR.
3. Dan reviews. **Request changes** and the bot revises; **approve** and it squash-merges, which closes
   the issue and unblocks issues that depended on it.

Everything is Terraform. Nothing here contains secrets: tokens live in `terraform/terraform.tfvars`
and the local state, both gitignored.

## How it works

The Droplet has two unprivileged users, so the AI never holds the GitHub token:

| User | Runs | Holds |
|---|---|---|
| `agent-ctl` | `agent/agent-poll.sh`, a plain bash loop (no AI). It does all GitHub work: reads issues, pushes, opens/merges PRs, comments, labels. | the bot's GitHub token |
| `agent` | Claude Code, via `agent/run-claude.sh`, the only command `agent-ctl` may `sudo` to. Has Python (uv), Node (fnm), .NET and rootless Docker. | the DO model key |

Each user has **its own copy of the repo**. Claude commits in `agent`'s copy. The commits come back
to `agent-ctl` as a single file (a git bundle), which `agent-ctl` loads into its private copy and pushes.
`agent-ctl` never runs git in a folder Claude can write to, because git hooks or config planted
there would run with the token. `agent` also can't reach the cloud metadata service, which serves
the user-data (and so the token).

The bot only acts on issues **opened by Dan and labelled `agent` by Dan**, and only feeds Dan's
comments and reviews to the model. It never creates issues, edits issue bodies or adds the `agent` label.

### Labels

| Label | Meaning |
|---|---|
| `agent` | Dan: "work on this". On a bot PR: "do another pass". |
| `agent:working` | A run is in progress. |
| `agent:review` | A PR is open for this issue. If the run stopped early (turn limit, timeout, an error) after making commits, the PR is a **draft** saying so: the bot leaves drafts alone, so check the work and mark it ready for review before approving or requesting changes. |
| `agent:blocked` | Waiting on open `Blocked by` issues (native dependencies or `Blocked by #N` / `Depends on #N` in the body). |
| `agent:needs-info` | The bot asked questions in a comment. Answer, then re-add `agent`. |
| `agent:failed` | The run failed without usable commits (or its push failed), or it used up `max_attempts` rate-limited runs; see its comment. Re-add `agent` to retry. |
| `agent:rate-limited` | Not enough model quota: the pre-flight check found under `min_quota_tokens` left, or the provider refused the run (HTTP 429). The bot runs no model jobs for `rate_limit_backoff` seconds (default 15 minutes), then checks the quota again, and keeps checking at that interval until `retry_quota_tokens` (default 4.5M, the full bucket) are free. It then retries this by itself, carrying on from any commits the cut-short run made and from the notes it kept as it went (findings, decisions, what's left), which go into the retry's prompt. Each retry that runs and gets limited again comments with its progress (attempt N of `max_attempts`); when the last attempt (default 5) is limited too, the bot comments that it reached the limit and marks it `agent:failed`. Checks that find too little quota leave the issue untouched. Remove the label to cancel. |

## Setup

### 1. Prerequisites

- [ ] DigitalOcean: prepaid balance added, **auto-reload off** (caps what a leaked model key can spend).
- [ ] DO model access key (Control panel → Inference → Manage → Model Access Keys), scoped to
      `anthropic-claude-5-sonnet` and `anthropic-claude-5.5-haiku` (DO has no Sonnet 5.5).
      Check it works and see the model IDs:
      ```bash
      curl -s https://inference.do-ai.run/v1/models -H "Authorization: Bearer $KEY" | jq -r '.data[].id'
      ```
- [ ] DO API token (read/write) for Terraform.
- [ ] Dan's own GitHub PAT with admin on `helix-reborn`, for Terraform (labels, ruleset).
- [ ] Bot account `helix-reborn-bot`: Write collaborator on `helix-reborn` (done by hand, not Terraform),
      2FA on, email private, classic PAT with `repo` scope only (**not** `workflow`).
- [ ] Terraform >= 1.6 locally.

### 2. Configure

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # fill in ssh_public_key, ssh_allowed_cidrs and both secrets
export DIGITALOCEAN_TOKEN=...                   # DO API token
export GITHUB_TOKEN=...                         # Dan's admin PAT (not the bot's)
```

The state holds the secrets (inside the Droplet's user-data). Keep it local and never commit it.

### 3. Apply

```bash
terraform init
terraform plan
terraform apply
```

This creates a DO project `helix-agent` holding the Droplet and a reserved IP, a firewall
(SSH from `ssh_allowed_cidrs` only), the six labels, and the default-branch ruleset.

The reserved IP gives the box a fixed hostname, `<reserved-ip>.sslip.io`
(`terraform output -raw hostname`), which stays the same when the Droplet is replaced.

First boot takes roughly 10 minutes (toolchains, Docker). Follow it with:

```bash
$(terraform output -raw cloud_init_log_command)   # ends with "helix-agent bootstrap finished"
$(terraform output -raw log_tail_command)         # the poll loop
```

### 4. Check the box

```bash
$(terraform output -raw ssh_command)
sudo -l -U agent-ctl                               # only /opt/agent/run-claude.sh, as agent
sudo -u agent cat /etc/agent/agent.env             # Permission denied
sudo -u agent curl -m3 http://169.254.169.254      # rejected
sudo -u agent-ctl docker ps                        # fails: agent-ctl has no Docker
systemctl is-active docker                         # inactive (no root daemon)
sudo -u agent grep -rl ghp_ /var/log /var/lib/cloud /run/cloud-init /srv 2>/dev/null   # nothing

# The toolchains and Docker, in the same environment run-claude.sh uses:
sudo -u agent bash -c 'export HOME=/home/agent XDG_RUNTIME_DIR=/run/user/$(id -u) DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock
  PATH=$HOME/.local/bin:$HOME/.local/share/fnm/aliases/default/bin:$HOME/.dotnet:$PATH; cd /tmp
  uv run --python 3.11 python --version; node --version; npm --version; dotnet --info | head -5; claude --version
  docker run --rm hello-world
  docker run --rm curlimages/curl -m3 http://169.254.169.254 && echo "METADATA REACHABLE: BAD"'
```

### 5. Try the loop

On a throwaway issue: label `agent` → PR appears → request changes → revision comment and commits
→ approve → merged and issue closed. Then a second issue with `Blocked by #<first>`: it should
get `agent:blocked` and wait until the first PR merges.

## Running it

- Label an issue `agent`. The timer polls every `poll_interval` (default 3 min); one model job per tick.
- Trigger a tick now: `systemctl start agent-poll` (as root on the box).
- Per-job logs: `/var/log/agent/<job>.log` (wrapper output, stderr, the quota check) and
  `<job>.jsonl` (Claude's stream-json events, one per line; the last is the result unless the
  run was killed). Each `api_retry` event is one retried model request.
- Quota: DO's daily token bucket refills slowly and a run uses ~2M tokens (cache reads count).
  Before each job, `run-claude.sh` makes a 1-token request and skips the job if fewer than
  `min_quota_tokens` are left. Claude Code retries a request only `model_max_retries` times, so
  a 429 mid-run ends the run quickly and the bot requeues it, instead of the run crawling from
  retry to retry until `job_timeout`. The requeued retry waits for `retry_quota_tokens` (the
  full bucket), and an issue or PR gets at most `max_attempts` runs per queueing. See what's left:
  `curl -s -o /dev/null -D - https://inference.do-ai.run/v1/messages -H "x-api-key: $KEY" -H 'anthropic-version: 2023-06-01' -H 'content-type: application/json' -d '{"model":"anthropic-claude-5-sonnet","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}' | grep -i remaining-tokens-per-day`
- A run the job timeout kills is reported as "timed out after …", with its API retries, its last
  message and the tokens it used up to then.
- Hand-over dirs from recent jobs: `/srv/agent-work/jobs/` (kept two days).
- Token usage: each PR body has a per-model table (input, output, cache read, cache write) with
  the total over every run on its issue (failed runs before the PR included) and the latest run;
  every bot comment after a run shows that run's usage (added up from the events, and marked
  partial, for a run that was killed). Running totals live in
  `/srv/agent-work/out/issue-<n>-usage.json`, which a Droplet replacement wipes.
  No dollar cost is shown: Claude Code's figure uses Anthropic list prices, not DO's.

## Changing settings

Any change to the scripts, prompts or variables changes the user-data, so `terraform apply`
**replaces the Droplet**. That's fine: it's stateless, and the reserved IP and hostname move to
the new one. The new box has new SSH host keys, so clear the old ones first:
`ssh-keygen -R $(terraform output -raw hostname)`.

If torch plus the Docker services run out of memory, set `droplet_size = "s-4vcpu-8gb"` (about $48/month).

## Teardown

Droplets bill while powered off, so destroy rather than stop:

```bash
terraform apply -var droplet_enabled=false   # removes only the Droplet; reserved IP, labels, ruleset, firewall stay
terraform destroy                            # everything
```

`s-2vcpu-4gb` costs about $24/month if left on. The reserved IP is free while assigned, but DO
bills a small hourly fee for it while the Droplet is gone; `terraform destroy` releases it. Model usage is billed separately from the prepaid
balance (see DO's pricing page for Sonnet 5 and Haiku 5.5). The cost Claude Code
reports may not match DO's billing.

## Layout

```
terraform/   providers, variables, Droplet + project + firewall, labels + ruleset, cloud-init
agent/       bootstrap.sh (first boot), agent-poll.sh (the loop), run-claude.sh (the sudo target),
             prompts, systemd units
```
