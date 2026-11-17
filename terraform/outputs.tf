locals {
  reserved_ip = digitalocean_reserved_ip.agent.ip_address
  hostname    = "${local.reserved_ip}.sslip.io"
  # Only usable while there is a Droplet behind the reserved IP.
  ssh_target = var.droplet_enabled ? "root@${local.hostname}" : null
}

output "reserved_ip" {
  description = "The bot's fixed public IPv4 (kept when the Droplet is replaced or destroyed)."
  value       = local.reserved_ip
}

output "hostname" {
  description = "sslip.io hostname that resolves to the reserved IP."
  value       = local.hostname
}

output "droplet_ip" {
  description = "The Droplet's own public IPv4, which changes with each replacement (null when droplet_enabled = false)."
  value       = one(digitalocean_droplet.agent[*].ipv4_address)
}

output "ssh_command" {
  description = "SSH in as root."
  value       = local.ssh_target == null ? null : "ssh ${local.ssh_target}"
}

output "cloud_init_log_command" {
  description = "Follow first-boot provisioning."
  value       = local.ssh_target == null ? null : "ssh ${local.ssh_target} tail -f /var/log/cloud-init-output.log"
}

output "log_tail_command" {
  description = "Follow the poll loop."
  value       = local.ssh_target == null ? null : "ssh ${local.ssh_target} journalctl -u agent-poll -f"
}
