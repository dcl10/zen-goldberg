terraform {
  required_version = ">= 1.6"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.70"
    }
    github = {
      source  = "integrations/github"
      version = "~> 6.6"
    }
  }
}

# Reads DIGITALOCEAN_TOKEN from the environment.
provider "digitalocean" {}

# Reads GITHUB_TOKEN from the environment: Dan's own PAT (admin on the repo), never the bot's.
provider "github" {
  owner = var.github_owner
}
