locals {
  agent_labels = {
    "agent"            = { color = "1d76db", description = "Queue for the bot (only the repo owner adds this). On a bot PR: ask for another pass." }
    "agent:working"    = { color = "fbca04", description = "The bot is working on this now." }
    "agent:review"     = { color = "0e8a16", description = "The bot opened a PR for this; waiting for review." }
    "agent:blocked"    = { color = "c5def5", description = "Waiting on open blocking issues." }
    "agent:needs-info" = { color = "d876e3", description = "The bot asked questions; answer, then re-add agent." }
    "agent:failed"     = { color = "b60205", description = "The bot's run failed; see its comment. Re-add agent to retry." }
  }
}

resource "github_issue_label" "agent" {
  for_each = var.manage_github ? local.agent_labels : {}

  repository  = var.github_repo
  name        = each.key
  color       = each.value.color
  description = each.value.description
}

# Rulesets are enforced on public repos, and on private repos only with GitHub Pro/Team.
# With enable_ruleset = false, the poll script's own approval check is the only gate.
resource "github_repository_ruleset" "default_branch" {
  count = var.manage_github && var.enable_ruleset ? 1 : 0

  name        = "helix-agent: protect default branch"
  repository  = var.github_repo
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
  }

  # Repository admins (Dan) may bypass; the bot is only a Write collaborator, so it can't.
  bypass_actors {
    actor_id    = 5
    actor_type  = "RepositoryRole"
    bypass_mode = "always"
  }

  rules {
    deletion         = true
    non_fast_forward = true

    pull_request {
      required_approving_review_count   = 1
      dismiss_stale_reviews_on_push     = true
      require_last_push_approval        = true
      require_code_owner_review         = false
      required_review_thread_resolution = false
    }

    dynamic "required_status_checks" {
      for_each = length(var.required_status_checks) > 0 ? [1] : []
      content {
        strict_required_status_checks_policy = false

        dynamic "required_check" {
          for_each = var.required_status_checks
          content {
            context = required_check.value
          }
        }
      }
    }
  }
}
