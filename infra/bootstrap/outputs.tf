output "state_bucket_name" {
  description = "S3 bucket name — use this in infra/terraform/backend.tf"
  value       = aws_s3_bucket.tfstate.id
}

output "state_bucket_arn" {
  description = "S3 bucket ARN"
  value       = aws_s3_bucket.tfstate.arn
}

output "lock_table_name" {
  description = "DynamoDB table name — use this in infra/terraform/backend.tf"
  value       = aws_dynamodb_table.tf_locks.name
}
