# ─── Network ──────────────────────────────────────────────────────────────────

output "vpc_id" {
  description = "VPC ID"
  value       = module.networking.vpc_id
}

output "public_subnet_ids" {
  description = "Public subnet IDs (bastion + ALB)"
  value       = module.networking.public_subnet_ids
}

output "private_app_subnet_ids" {
  description = "Private app subnet IDs (frontend + backend)"
  value       = module.networking.private_app_subnet_ids
}

output "private_db_subnet_ids" {
  description = "Private DB subnet IDs"
  value       = module.networking.private_db_subnet_ids
}

# ─── Security Groups ──────────────────────────────────────────────────────────

output "alb_sg_id" {
  description = "ALB security group ID"
  value       = module.security.alb_sg_id
}

output "bastion_sg_id" {
  description = "Bastion security group ID"
  value       = module.security.bastion_sg_id
}

output "frontend_sg_id" {
  description = "Frontend security group ID"
  value       = module.security.frontend_sg_id
}

output "backend_sg_id" {
  description = "Backend security group ID"
  value       = module.security.backend_sg_id
}

output "db_sg_id" {
  description = "DB security group ID"
  value       = module.security.db_sg_id
}

# ─── Compute ──────────────────────────────────────────────────────────────────

output "bastion_public_ip" {
  description = "Bastion public IP — SSH entry point"
  value       = module.compute.bastion_public_ip
}

output "frontend_private_ip" {
  description = "Frontend EC2 private IP"
  value       = module.compute.frontend_private_ip
}

output "backend_private_ip" {
  description = "Backend EC2 private IP"
  value       = module.compute.backend_private_ip
}

output "db_private_ip" {
  description = "DB EC2 private IP"
  value       = module.compute.db_private_ip
}

output "ssh_bastion" {
  description = "SSH command for bastion"
  value       = "ssh -i ~/.ssh/voting-app ubuntu@${module.compute.bastion_public_ip}"
}

output "ssh_frontend_via_bastion" {
  description = "SSH command for frontend via ProxyJump"
  value       = "ssh -i ~/.ssh/voting-app -J ubuntu@${module.compute.bastion_public_ip} ubuntu@${module.compute.frontend_private_ip}"
}

# ─── ALB ──────────────────────────────────────────────────────────────────────

output "alb_dns_name" {
  description = "ALB DNS name — public entry point"
  value       = module.alb.alb_dns_name
}

output "vote_url" {
  description = "Vote app URL"
  value       = "http://${module.alb.alb_dns_name}/"
}

output "result_url" {
  description = "Result app URL"
  value       = "http://${module.alb.alb_dns_name}/result"
}
