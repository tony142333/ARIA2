# Security Group for aria2 Instance
resource "aws_security_group" "aria2" {
  name        = "${var.project_name}-sg"
  description = "Security group for aria2 downloader instance"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-sg"
  }
}

# SSH Access
resource "aws_security_group_rule" "ssh" {
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = [var.allowed_ssh_cidr]
  security_group_id = aws_security_group.aria2.id
  description       = "SSH access"
}

# aria2 Web UI Access
resource "aws_security_group_rule" "aria2_web" {
  type              = "ingress"
  from_port         = var.aria2_web_port
  to_port           = var.aria2_web_port
  protocol          = "tcp"
  cidr_blocks       = [var.allowed_web_cidr]
  security_group_id = aws_security_group.aria2.id
  description       = "aria2 Web UI access"
}

# aria2 RPC Access
resource "aws_security_group_rule" "aria2_rpc" {
  type              = "ingress"
  from_port         = var.aria2_rpc_port
  to_port           = var.aria2_rpc_port
  protocol          = "tcp"
  cidr_blocks       = [var.allowed_web_cidr]
  security_group_id = aws_security_group.aria2.id
  description       = "aria2 RPC access"
}

# Allow all outbound traffic
resource "aws_security_group_rule" "egress_all" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.aria2.id
  description       = "Allow all outbound traffic"
}
