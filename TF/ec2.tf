# Get latest Ubuntu 22.04 AMI
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Priority-based User Data Execution Router
locals {
  userdata_aria2 = file("${path.module}/user_data_blocks/userdata_aria2.sh")
  userdata_app   = templatefile("${path.module}/user_data_blocks/userdata_app.sh", {
    git_branch = var.git_branch
  })

  # Order scripts based on priority_app when running both (Defaults to aria2 first)
  both_combined = (
    var.priority_app == "aria2"
    ? "${local.userdata_aria2}\n\n${local.userdata_app}"
    : "${local.userdata_app}\n\n${local.userdata_aria2}"
  )

  # Final userdata payload selection
  selected_userdata = (
    var.execution_mode == "aria2" ? local.userdata_aria2 :
      var.execution_mode == "app"   ? local.userdata_app :
      local.both_combined
  )
}

# EC2 Instance
resource "aws_instance" "aria2" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = var.ssh_key_name
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.aria2.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name

  user_data = local.selected_userdata

  root_block_device {
    volume_size = 60
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name = "${var.project_name}-instance"
  }
}

# Elastic IP for consistent access
resource "aws_eip" "aria2" {
  instance = aws_instance.aria2.id
  domain   = "vpc"

  tags = {
    Name = "${var.project_name}-eip"
  }

  depends_on = [aws_internet_gateway.main]
}