locals {
  agent_dir = "${path.module}/../agent"

  # /etc/agent/agent.env, read by systemd (EnvironmentFile) for agent-poll.service only.
  # Every value is validated in variables.tf, so plain double quotes are safe (single quotes
  # for the JSON, which has no single quotes in it).
  agent_env = <<-EOT
    AGENT_REPO="${var.github_owner}/${var.github_repo}"
    AGENT_DEFAULT_BRANCH="${var.default_branch}"
    AGENT_OWNER="${var.owner_login}"
    AGENT_BOT="${var.bot_login}"
    AGENT_MODEL="${var.model}"
    AGENT_MAX_TURNS="${var.max_turns}"
    AGENT_JOB_TIMEOUT="${var.job_timeout}"
    AGENT_AUTO_MERGE="${var.auto_merge_on_approval}"
    AGENT_MIN_QUOTA_TOKENS="${var.min_quota_tokens}"
    AGENT_RATE_LIMIT_BACKOFF="${var.rate_limit_backoff}"
    AGENT_MODEL_IDS='${jsonencode(var.model_overrides)}'
    GH_TOKEN="${var.bot_github_token}"
  EOT

  # Read by bootstrap.sh (root) once, at first boot.
  bootstrap_env = <<-EOT
    NODE_VERSION="${var.node_version}"
    DOTNET_CHANNEL="${var.dotnet_channel}"
  EOT

  claude_settings = jsonencode({
    apiKeyHelper = "cat /etc/agent/model-key"
    # Maps Anthropic IDs to DO's, so Claude Code knows what each DO ID is (context window,
    # thinking, effort) instead of guessing.
    modelOverrides = var.model_overrides
    env = {
      ANTHROPIC_BASE_URL                       = "https://inference.do-ai.run"
      CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS   = "1"
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1"
      DISABLE_AUTOUPDATER                      = "1"
      # Few retries, so a quota 429 ends the run (and the poll script requeues it) instead of
      # the run crawling from retry to retry until the job timeout.
      CLAUDE_CODE_MAX_RETRIES = tostring(var.model_max_retries)
      # Every alias lands on a model the key allows. The key has no Opus, so opus goes to
      # the main model too.
      ANTHROPIC_DEFAULT_SONNET_MODEL = var.model
      ANTHROPIC_DEFAULT_OPUS_MODEL   = var.model
      ANTHROPIC_DEFAULT_HAIKU_MODEL  = var.small_fast_model
    }
  })

  # gitconfig double-quoted values use the same escapes as JSON for ordinary text.
  bot_gitconfig = <<-EOT
    [user]
    	name = ${jsonencode(var.bot_git_name)}
    	email = ${jsonencode(var.bot_git_email)}
    [init]
    	defaultBranch = main
  EOT

  # Files cloud-init writes. `defer` delays a file until after the users exist (needed for
  # any owner other than root). Content is base64 so YAML quoting can never break it, and
  # gzipped first to keep user_data under DO's 64 KB limit.
  files = [
    { path = "/opt/agent/bootstrap.sh", content = base64gzip(file("${local.agent_dir}/bootstrap.sh")), owner = "root:root", permissions = "0700", defer = false },
    { path = "/opt/agent/agent-poll.sh", content = base64gzip(file("${local.agent_dir}/agent-poll.sh")), owner = "root:root", permissions = "0755", defer = false },
    { path = "/opt/agent/run-claude.sh", content = base64gzip(file("${local.agent_dir}/run-claude.sh")), owner = "root:root", permissions = "0755", defer = false },
    { path = "/opt/agent/prompt-issue.md", content = base64gzip(file("${local.agent_dir}/prompt-issue.md")), owner = "root:root", permissions = "0644", defer = false },
    { path = "/opt/agent/prompt-revise.md", content = base64gzip(file("${local.agent_dir}/prompt-revise.md")), owner = "root:root", permissions = "0644", defer = false },
    { path = "/etc/systemd/system/agent-poll.service", content = base64gzip(file("${local.agent_dir}/agent-poll.service")), owner = "root:root", permissions = "0644", defer = false },
    { path = "/etc/systemd/system/agent-firewall.service", content = base64gzip(file("${local.agent_dir}/agent-firewall.service")), owner = "root:root", permissions = "0644", defer = false },
    { path = "/etc/systemd/system/agent-poll.timer", content = base64gzip(templatefile("${local.agent_dir}/agent-poll.timer.tftpl", { poll_interval = var.poll_interval })), owner = "root:root", permissions = "0644", defer = false },
    { path = "/etc/sudoers.d/agent-ctl", content = base64gzip("agent-ctl ALL=(agent) NOPASSWD: /opt/agent/run-claude.sh\n"), owner = "root:root", permissions = "0440", defer = false },
    { path = "/etc/agent/bootstrap.env", content = base64gzip(local.bootstrap_env), owner = "root:root", permissions = "0600", defer = false },
    { path = "/etc/agent/agent.env", content = base64gzip(local.agent_env), owner = "agent-ctl:agent-ctl", permissions = "0600", defer = true },
    { path = "/etc/agent/model-key", content = base64gzip(var.do_model_access_key), owner = "agent:agent", permissions = "0600", defer = true },
    { path = "/home/agent/.claude/settings.json", content = base64gzip(local.claude_settings), owner = "agent:agent", permissions = "0644", defer = true },
    { path = "/home/agent/.gitconfig", content = base64gzip(local.bot_gitconfig), owner = "agent:agent", permissions = "0644", defer = true },
    { path = "/home/agent-ctl/.gitconfig", content = base64gzip(local.bot_gitconfig), owner = "agent-ctl:agent-ctl", permissions = "0644", defer = true },
  ]

  user_data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    ssh_public_key = var.ssh_public_key
    files          = local.files
  })
}

# Groups the bot's resources in the DO control panel. Only the Droplet can join a project
# (firewalls and tags can't); the list is empty while droplet_enabled = false.
resource "digitalocean_project" "agent" {
  name        = var.project_name
  description = "Unattended Claude Code bot for Helix Reborn (managed by Terraform)."
  purpose     = "Service or API"
  environment = "Development"
  resources   = concat([digitalocean_reserved_ip.agent.urn], digitalocean_droplet.agent[*].urn)
}

# A fixed address (and so a fixed <ip>.sslip.io hostname) that survives the Droplet being
# replaced or destroyed. Free while assigned; DO bills a small hourly fee while it isn't.
resource "digitalocean_reserved_ip" "agent" {
  region = var.region
}

resource "digitalocean_reserved_ip_assignment" "agent" {
  count = var.droplet_enabled ? 1 : 0

  ip_address = digitalocean_reserved_ip.agent.ip_address
  droplet_id = digitalocean_droplet.agent[0].id
}

resource "digitalocean_tag" "agent" {
  name = "helix-agent"
}

# Registering the key with DigitalOcean (not just installing it via cloud-init) stops DO from
# giving root an expired, emailed password that must be changed at first login.
resource "digitalocean_ssh_key" "agent" {
  name       = "helix-agent"
  public_key = var.ssh_public_key
}

# Stateless: any change to user_data (scripts, secrets, settings) replaces the box.
resource "digitalocean_droplet" "agent" {
  count = var.droplet_enabled ? 1 : 0

  name       = "helix-agent"
  region     = var.region
  size       = var.droplet_size
  image      = var.droplet_image
  monitoring = true
  tags       = [digitalocean_tag.agent.id]
  ssh_keys   = [digitalocean_ssh_key.agent.fingerprint]
  user_data  = local.user_data
}

# Attached by tag, so it survives the Droplet being destroyed and recreated.
resource "digitalocean_firewall" "agent" {
  name = "helix-agent"
  tags = [digitalocean_tag.agent.id]

  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = var.ssh_allowed_cidrs
  }

  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  # DNS.
  outbound_rule {
    protocol              = "udp"
    port_range            = "53"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  # NTP, so the clock (TLS, commit dates the poll script compares) stays right.
  outbound_rule {
    protocol              = "udp"
    port_range            = "123"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}
