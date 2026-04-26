locals {
  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  user_data = <<-EOF
    #!/bin/bash
    apt-get update -y
    apt-get install -y ca-certificates curl gnupg
  EOF
}

# ─── Key Pair ─────────────────────────────────────────────────────────────────

resource "aws_key_pair" "main" {
  key_name   = var.key_name
  public_key = file(var.public_key_path)

  tags = local.tags
}

# ─── IAM Role (SSM + CloudWatch) ─────────────────────────────────────────────

resource "aws_iam_role" "ec2" {
  name = "${var.project}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cloudwatch" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.project}-ec2-profile"
  role = aws_iam_role.ec2.name
}

# ─── Bastion ──────────────────────────────────────────────────────────────────

resource "aws_instance" "bastion" {
  ami                    = var.ami_id
  instance_type          = var.bastion_instance_type
  subnet_id              = var.public_subnet_ids[0]
  vpc_security_group_ids = [var.bastion_sg_id]
  key_name               = aws_key_pair.main.key_name
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  user_data = local.user_data

  tags = merge(local.tags, {
    Name = "${var.project}-bastion"
    Role = "bastion"
  })
}

# ─── Frontend (vote + result) ─────────────────────────────────────────────────

resource "aws_instance" "frontend" {
  ami                    = var.ami_id
  instance_type          = var.app_instance_type
  subnet_id              = var.private_app_subnet_ids[0]
  vpc_security_group_ids = [var.frontend_sg_id]
  key_name               = aws_key_pair.main.key_name
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  user_data = local.user_data

  tags = merge(local.tags, {
    Name = "${var.project}-frontend"
    Role = "frontend"
  })
}

# ─── Backend (Redis + worker) ─────────────────────────────────────────────────

resource "aws_instance" "backend" {
  ami                    = var.ami_id
  instance_type          = var.app_instance_type
  subnet_id              = var.private_app_subnet_ids[0]
  vpc_security_group_ids = [var.backend_sg_id]
  key_name               = aws_key_pair.main.key_name
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  user_data = local.user_data

  tags = merge(local.tags, {
    Name = "${var.project}-backend"
    Role = "backend"
  })
}

# ─── DB (Postgres) ────────────────────────────────────────────────────────────

resource "aws_instance" "db" {
  ami                    = var.ami_id
  instance_type          = var.app_instance_type
  subnet_id              = var.private_db_subnet_ids[0]
  vpc_security_group_ids = [var.db_sg_id]
  key_name               = aws_key_pair.main.key_name
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  user_data = local.user_data

  tags = merge(local.tags, {
    Name = "${var.project}-db"
    Role = "db"
  })
}
