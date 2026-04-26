variable "project" {
  type = string
}

variable "environment" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "my_ip_cidr" {
  type        = string
  description = "Operator IP in CIDR form — restricts bastion SSH"
}
