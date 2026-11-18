# ---------------------------------------------------------------------------
# Toggles
# ---------------------------------------------------------------------------

variable "droplet_enabled" {
  description = "Create the bot Droplet. Set false (terraform apply -var droplet_enabled=false) to destroy only the box; Droplets bill while powered off."
  type        = bool
  default     = true
}

variable "manage_github" {
  description = "Manage the agent labels (and the ruleset, if enable_ruleset) on the GitHub repo."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# Droplet
# ---------------------------------------------------------------------------

variable "project_name" {
  description = "DigitalOcean project the Droplet is placed in."
  type        = string
  default     = "helix-agent"
}

variable "region" {
  description = "DigitalOcean region slug."
  type        = string
  default     = "lon1"
}

variable "droplet_size" {
  description = "Droplet size. torch needs 4 GB plus swap; move to s-4vcpu-8gb (about $48/month) if torch plus the Docker services run out of memory."
  type        = string
  default     = "s-2vcpu-4gb"
}

variable "droplet_image" {
  description = "Droplet image. cloud-init assumes Ubuntu 24.04 (package names such as libicu74)."
  type        = string
  default     = "ubuntu-24-04-x64"
}

variable "ssh_public_key" {
  description = "Contents of the SSH public key allowed to log in as root, e.g. \"ssh-ed25519 AAAA... dan@mac\". Registered as a DigitalOcean account key (so root gets no password) and installed by cloud-init."
  type        = string

  validation {
    condition     = can(regex("^(ssh-(ed25519|rsa)|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com) ", var.ssh_public_key))
    error_message = "ssh_public_key must be the contents of a public key (starting with ssh-ed25519, ssh-rsa, ...), not a path."
  }
}

variable "ssh_allowed_cidrs" {
  description = "CIDRs allowed to reach SSH (TCP 22). Keep this to your own IP, e.g. [\"203.0.113.7/32\"]."
  type        = list(string)

  validation {
    condition     = length(var.ssh_allowed_cidrs) > 0 && alltrue([for c in var.ssh_allowed_cidrs : can(cidrhost(c, 0))])
    error_message = "ssh_allowed_cidrs must be a non-empty list of valid CIDRs."
  }
}

# ---------------------------------------------------------------------------
# Secrets. They end up in user-data and therefore in the Terraform state:
# keep the state local and gitignored.
# ---------------------------------------------------------------------------

variable "do_model_access_key" {
  description = "DigitalOcean serverless inference model access key (doo_v1_...). Readable by the agent user only."
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+$", var.do_model_access_key))
    error_message = "do_model_access_key must be set (letters, digits, '_', '.', '-')."
  }
}

variable "bot_github_token" {
  description = "The bot account's classic PAT (repo scope, not workflow). Readable by the agent-ctl user only."
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[A-Za-z0-9_]+$", var.bot_github_token))
    error_message = "bot_github_token must be set (a ghp_... or github_pat_... token)."
  }
}

# ---------------------------------------------------------------------------
# Model
# ---------------------------------------------------------------------------

# DO names models differently from Anthropic (anthropic-claude-5-sonnet, not claude-sonnet-5),
# so aliases like `sonnet` don't work there: use exact IDs from
#   curl -s https://inference.do-ai.run/v1/models -H "Authorization: Bearer $KEY" | jq -r '.data[].id'
# DO offers no Sonnet 5.5; Sonnet 5 is its newest Sonnet.

variable "model" {
  description = "Exact DO model ID for the main work (claude --model). Also what the sonnet and opus aliases resolve to, so subagents asking for either stay on a model the key allows."
  type        = string
  default     = "anthropic-claude-5-sonnet"

  validation {
    condition     = can(regex("^[A-Za-z0-9._-]+$", var.model))
    error_message = "model may only contain letters, digits, '.', '_' and '-'."
  }
}

variable "small_fast_model" {
  description = "Exact DO model ID for Claude Code's background tasks and the haiku alias (ANTHROPIC_DEFAULT_HAIKU_MODEL)."
  type        = string
  default     = "anthropic-claude-5.5-haiku"

  validation {
    condition     = can(regex("^[A-Za-z0-9._-]+$", var.small_fast_model))
    error_message = "small_fast_model may only contain letters, digits, '.', '_' and '-'."
  }
}

variable "model_overrides" {
  description = "Claude Code modelOverrides: Anthropic model ID => DO model ID. Tells Claude Code which model each DO ID really is, so it uses the right context window and enables thinking/effort; IDs it doesn't recognise get a guessed window and an 'unrecognized model' warning. Keep in step with model and small_fast_model."
  type        = map(string)
  default = {
    "claude-sonnet-5"  = "anthropic-claude-5-sonnet"
    "claude-haiku-5-5" = "anthropic-claude-5.5-haiku"
  }

  validation {
    condition     = alltrue([for k, v in var.model_overrides : can(regex("^claude-[a-z0-9-]+$", k)) && can(regex("^[A-Za-z0-9._-]+$", v))])
    error_message = "model_overrides keys must be Anthropic model IDs (claude-...) and values DO model IDs."
  }
}

variable "max_turns" {
  description = "claude --max-turns per job."
  type        = number
  default     = 80

  validation {
    condition     = var.max_turns >= 1 && var.max_turns == floor(var.max_turns)
    error_message = "max_turns must be a positive whole number."
  }
}

variable "job_timeout" {
  description = "Wall-clock limit per model job, in timeout(1) syntax (e.g. 45m)."
  type        = string
  default     = "45m"

  validation {
    condition     = can(regex("^[0-9]+[smh]?$", var.job_timeout))
    error_message = "job_timeout must look like 45m, 2h or 900s."
  }
}

variable "poll_interval" {
  description = "Gap between poll runs (systemd time span, e.g. 3min)."
  type        = string
  default     = "3min"

  validation {
    condition     = can(regex("^[0-9]+(s|sec|min|m|h)$", var.poll_interval))
    error_message = "poll_interval must look like 3min, 90s or 1h."
  }
}

# ---------------------------------------------------------------------------
# Toolchains on the box
# ---------------------------------------------------------------------------

variable "node_version" {
  description = "Node.js version for fnm (fnm install <x>; 'lts-latest' installs the current LTS)."
  type        = string
  default     = "lts-latest"

  validation {
    condition     = can(regex("^[A-Za-z0-9._-]+$", var.node_version))
    error_message = "node_version may only contain letters, digits, '.', '_' and '-'."
  }
}

variable "dotnet_channel" {
  description = ".NET SDK channel for dotnet-install.sh --channel (LTS, STS or e.g. 9.0)."
  type        = string
  default     = "LTS"

  validation {
    condition     = can(regex("^[A-Za-z0-9.]+$", var.dotnet_channel))
    error_message = "dotnet_channel may only contain letters, digits and '.'."
  }
}

# ---------------------------------------------------------------------------
# GitHub
# ---------------------------------------------------------------------------

variable "github_owner" {
  description = "Owner of the Helix Reborn repo (also the github provider's owner)."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9-]+$", var.github_owner))
    error_message = "github_owner must be a GitHub login."
  }
}

variable "github_repo" {
  description = "Name of the Helix Reborn repo (without the owner)."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9._-]+$", var.github_repo))
    error_message = "github_repo must be a repository name without the owner."
  }
}

variable "default_branch" {
  description = "Branch the bot branches from and opens PRs against."
  type        = string
  default     = "main"

  validation {
    condition     = can(regex("^[A-Za-z0-9._/-]+$", var.default_branch))
    error_message = "default_branch may only contain letters, digits, '.', '_', '/' and '-'."
  }
}

variable "owner_login" {
  description = "GitHub login of the only person whose issues, labels, reviews and comments the bot acts on."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9-]+$", var.owner_login))
    error_message = "owner_login must be a GitHub login."
  }
}

variable "bot_login" {
  description = "GitHub login of the bot account."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9-]+$", var.bot_login))
    error_message = "bot_login must be a GitHub login."
  }
}

variable "bot_git_name" {
  description = "git user.name for the bot's commits."
  type        = string

  validation {
    condition     = length(var.bot_git_name) > 0 && !can(regex("[\\n\\r]", var.bot_git_name))
    error_message = "bot_git_name must be a single non-empty line."
  }
}

variable "bot_git_email" {
  description = "git user.email for the bot's commits (its noreply address)."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+$", var.bot_git_email))
    error_message = "bot_git_email must be an email address."
  }
}

# ---------------------------------------------------------------------------
# Behaviour
# ---------------------------------------------------------------------------

variable "auto_merge_on_approval" {
  description = "Squash-merge the bot's PR once owner_login has approved its current head and GitHub reports it mergeable."
  type        = bool
  default     = true
}

variable "required_status_checks" {
  description = "CI check names the ruleset requires before merge, e.g. [\"run_unit_tests\", \"format_python_code\", \"code_quality_check\"]."
  type        = list(string)
  default     = []
}

variable "enable_ruleset" {
  description = "Create the default-branch ruleset. Rulesets are enforced on public repos, or on private repos only with GitHub Pro/Team."
  type        = bool
  default     = true
}
