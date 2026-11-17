# zen-goldberg

Infrastructure for an unattended Claude Code bot that works on
[Helix Reborn](https://github.com/dcl10/helix-reborn). It runs on a DigitalOcean Droplet and uses
DigitalOcean serverless inference (Sonnet 5.5), not a Claude subscription.

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
| `agent:review` | A PR is open for this issue. |
| `agent:blocked` | Waiting on open `Blocked by` issues (native dependencies or `Blocked by #N` / `Depends on #N` in the body). |
| `agent:needs-info` | The bot asked questions in a comment. Answer, then re-add `agent`. |
| `agent:failed` | The run failed; see its comment. Re-add `agent` to retry. |

## Setup

### 1. Prerequisites

- [ ] DigitalOcean: prepaid balance added, **auto-reload off** (caps what a leaked model key can spend).
- [ ] DO model access key (Control panel → Agent Platform → Model access keys), ideally scoped to
      Sonnet 5.5 + Haiku 5.5. Check it works and see the model IDs:
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

This creates a DO project `helix-agent` with the Droplet in it, a firewall (SSH from
`ssh_allowed_cidrs` only), the six labels, and the default-branch ruleset.

First boot takes roughly 10 minutes (toolchains, Docker). Follow it with:

```bash
$(terraform output -raw cloud_init_log_command)   # ends with "helix-agent bootstrap finished"
$(terraform output -raw log_tail_command)         # the poll loop
```

### 4. Check the box

```bash
ssh root@$(terraform output -raw droplet_ip)
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
- Per-job logs: `/var/log/agent/<job>.log` (wrapper output, stderr) and `<job>.json` (Claude's JSON result).
- Hand-over dirs from recent jobs: `/srv/agent-work/jobs/` (kept two days).

## Changing settings

Any change to the scripts, prompts or variables changes the user-data, so `terraform apply`
**replaces the Droplet**. That's fine: it's stateless.

If torch plus the Docker services run out of memory, set `droplet_size = "s-4vcpu-8gb"` (about $48/month).

## Teardown

Droplets bill while powered off, so destroy rather than stop:

```bash
terraform apply -var droplet_enabled=false   # removes only the Droplet; labels, ruleset, firewall stay
terraform destroy                            # everything
```

`s-2vcpu-4gb` costs about $24/month if left on. Model usage is billed separately from the prepaid
balance (roughly $2 / $10 per million input / output tokens for Sonnet 5.5). The cost Claude Code
reports may not match DO's billing.

## Layout

```
terraform/   providers, variables, Droplet + project + firewall, labels + ruleset, cloud-init
agent/       bootstrap.sh (first boot), agent-poll.sh (the loop), run-claude.sh (the sudo target),
             prompts, systemd units
```
