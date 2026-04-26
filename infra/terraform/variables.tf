variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project name — used in tags and resource names"
  type        = string
  default     = "voting-app"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev"
}

# ─── Networking ──────────────────────────────────────────────────────────────

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "azs" {
  description = "Availability zones to use (must be at least 2 for ALB)"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "public_subnet_cidrs" {
  description = "CIDRs for public subnets (one per AZ — bastion + ALB)"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_app_subnet_cidrs" {
  description = "CIDRs for private app subnets (frontend + backend)"
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24"]
}

variable "private_db_subnet_cidrs" {
  description = "CIDRs for private DB subnets"
  type        = list(string)
  default     = ["10.0.20.0/24", "10.0.21.0/24"]
}

# ─── Compute ─────────────────────────────────────────────────────────────────

variable "key_name" {
  description = "EC2 key pair name (must exist in AWS)"
  type        = string
}

variable "public_key_path" {
  description = "Path to the public key file to upload as an EC2 key pair"
  type        = string
  default     = "~/.ssh/voting-app.pub"
}

variable "bastion_instance_type" {
  description = "Instance type for the bastion host"
  type        = string
  default     = "t3.nano"
}

variable "app_instance_type" {
  description = "Instance type for app EC2s (frontend, backend, db)"
  type        = string
  default     = "t3.micro"
}

variable "ami_id" {
  description = "AMI ID — Ubuntu 22.04 LTS in us-east-1"
  type        = string
  default     = "ami-0e001c9271cf7f3b9" # Ubuntu 22.04 LTS us-east-1
}

# ─── Security ────────────────────────────────────────────────────────────────

variable "my_ip_cidr" {
  description = "Your public IP in CIDR form (e.g. 1.2.3.4/32) — restricts bastion SSH inbound"
  type        = string
}
