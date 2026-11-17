locals {
  droplet_ip = one(digitalocean_droplet.agent[*].ipv4_address)
}

output "droplet_ip" {
  description = "Public IPv4 of the bot Droplet (null when droplet_enabled = false)."
  value       = local.droplet_ip
}

output "ssh_command" {
  description = "SSH in as root."
  value       = local.droplet_ip == null ? null : "ssh root@${local.droplet_ip}"
}

output "cloud_init_log_command" {
  description = "Follow first-boot provisioning."
  value       = local.droplet_ip == null ? null : "ssh root@${local.droplet_ip} tail -f /var/log/cloud-init-output.log"
}

output "log_tail_command" {
  description = "Follow the poll loop."
  value       = local.droplet_ip == null ? null : "ssh root@${local.droplet_ip} journalctl -u agent-poll -f"
}
