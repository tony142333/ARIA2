output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.main.id
}

output "instance_id" {
  description = "ID of the EC2 instance"
  value       = aws_instance.aria2.id
}

output "instance_public_ip" {
  description = "Public IP address of the instance (Elastic IP)"
  value       = aws_eip.aria2.public_ip
}

output "aria2_web_ui_url" {
  description = "URL to access aria2 web UI"
  value       = "http://${aws_eip.aria2.public_ip}:${var.aria2_web_port}"
}

output "ssh_command" {
  description = "SSH command to connect to the instance"
  value       = "ssh -i ${var.ssh_key_name}.pem ubuntu@${aws_eip.aria2.public_ip}"
}

output "rpc_configuration" {
  description = "RPC configuration for AriaNg web UI"
  value = {
    address  = aws_eip.aria2.public_ip
    port     = var.aria2_rpc_port
    secret   = "aria2secret"
    protocol = "http://"
  }
}

output "downloads_directory" {
  description = "Directory where downloaded files are stored on the instance"
  value       = "/home/ubuntu/downloads"
}

output "iam_role" {
  description = "IAM role attached to instance for S3 access"
  value       = aws_iam_role.ec2_s3_access.name
}
output "stream_grabber" {
  description = "stream_grabber Web Interface URL"
  value       = "http://${aws_eip.aria2.public_ip}:8085"
}

output "branch" {
  description = "Branch used"
  value = "${var.git_branch}"
}

# In outputs.tf
output "deployment_source" {
  description = "Git branch and exact commit deployed to the EC2 instance"
  value = {
    branch       = var.app_branch
    commit_sha   = data.external.git_commit.result.commit
    short_sha    = data.external.git_commit.result.short_commit
  }
}