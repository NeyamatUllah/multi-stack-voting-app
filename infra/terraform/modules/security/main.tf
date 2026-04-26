locals {
  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# ─── ALB SG ──────────────────────────────────────────────────────────────────
# Public-facing: accepts HTTP from anywhere

resource "aws_security_group" "alb" {
  name        = "${var.project}-sg-alb"
  description = "ALB - inbound HTTP from internet"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTP from internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${var.project}-sg-alb" })
}

# ─── Bastion SG ───────────────────────────────────────────────────────────────
# SSH only from operator IP

resource "aws_security_group" "bastion" {
  name        = "${var.project}-sg-bastion"
  description = "Bastion - inbound SSH from operator IP only"
  vpc_id      = var.vpc_id

  ingress {
    description = "SSH from operator"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${var.project}-sg-bastion" })
}

# ─── Frontend SG ──────────────────────────────────────────────────────────────
# HTTP from ALB SG; SSH from bastion SG

resource "aws_security_group" "frontend" {
  name        = "${var.project}-sg-frontend"
  description = "Frontend - HTTP from ALB, SSH from bastion"
  vpc_id      = var.vpc_id

  ingress {
    description     = "HTTP vote (5000) from ALB"
    from_port       = 5000
    to_port         = 5000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    description     = "HTTP result (5001) from ALB"
    from_port       = 5001
    to_port         = 5001
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    description     = "SSH from bastion"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${var.project}-sg-frontend" })
}

# ─── Backend SG ───────────────────────────────────────────────────────────────
# Redis (6379) from frontend SG only — worker runs on this same EC2, uses localhost

resource "aws_security_group" "backend" {
  name        = "${var.project}-sg-backend"
  description = "Backend - Redis from frontend, SSH from bastion"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Redis from frontend (vote app)"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.frontend.id]
  }

  ingress {
    description     = "SSH from bastion"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${var.project}-sg-backend" })
}

# ─── DB SG ────────────────────────────────────────────────────────────────────
# Postgres (5432) from backend SG (worker) and frontend SG (result app)

resource "aws_security_group" "db" {
  name        = "${var.project}-sg-db"
  description = "DB - Postgres from backend/worker and frontend/result, SSH from bastion"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Postgres from backend (worker)"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.backend.id]
  }

  ingress {
    description     = "Postgres from frontend (result app)"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.frontend.id]
  }

  ingress {
    description     = "SSH from bastion"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${var.project}-sg-db" })
}
