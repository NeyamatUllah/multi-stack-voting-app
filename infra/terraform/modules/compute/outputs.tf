output "bastion_public_ip" {
  value = aws_instance.bastion.public_ip
}

output "bastion_instance_id" {
  value = aws_instance.bastion.id
}

output "frontend_private_ip" {
  value = aws_instance.frontend.private_ip
}

output "frontend_instance_id" {
  value = aws_instance.frontend.id
}

output "backend_private_ip" {
  value = aws_instance.backend.private_ip
}

output "backend_instance_id" {
  value = aws_instance.backend.id
}

output "db_private_ip" {
  value = aws_instance.db.private_ip
}

output "db_instance_id" {
  value = aws_instance.db.id
}

output "iam_instance_profile_name" {
  value = aws_iam_instance_profile.ec2.name
}
