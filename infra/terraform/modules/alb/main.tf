locals {
  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# ─── ALB ──────────────────────────────────────────────────────────────────────

resource "aws_lb" "main" {
  name               = "${var.project}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.alb_sg_id]
  subnets            = var.public_subnet_ids

  tags = merge(local.tags, { Name = "${var.project}-alb" })
}

# ─── Target Groups ────────────────────────────────────────────────────────────

resource "aws_lb_target_group" "vote" {
  name     = "${var.project}-vote-tg"
  port     = 5000
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  health_check {
    path                = "/"
    port                = "5000"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
    matcher             = "200"
  }

  tags = merge(local.tags, { Name = "${var.project}-vote-tg" })
}

resource "aws_lb_target_group" "result" {
  name     = "${var.project}-result-tg"
  port     = 5001
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  health_check {
    path                = "/"
    port                = "5001"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
    matcher             = "200"
  }

  tags = merge(local.tags, { Name = "${var.project}-result-tg" })
}

resource "aws_lb_target_group_attachment" "vote" {
  target_group_arn = aws_lb_target_group.vote.arn
  target_id        = var.frontend_instance_id
  port             = 5000
}

resource "aws_lb_target_group_attachment" "result" {
  target_group_arn = aws_lb_target_group.result.arn
  target_id        = var.frontend_instance_id
  port             = 5001
}

# ─── Listener + Rules ─────────────────────────────────────────────────────────

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  # Default: send to vote app
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.vote.arn
  }
}

resource "aws_lb_listener_rule" "result" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.result.arn
  }

  condition {
    path_pattern {
      values = ["/result", "/result/*"]
    }
  }
}
