# AWS Configuration
aws_region = "us-east-1"
environment = "dev"

# Network Configuration
vpc_cidr           = "10.0.0.0/16"
public_subnet_cidr = "10.0.1.0/24"
availability_zone  = "us-east-1a"

# Instance Configuration
instance_type = "t3.small"

# aria2 Configuration
aria2_web_port = 8080
aria2_rpc_port = 6800

# Security Configuration
allowed_ssh_cidr = "0.0.0.0/0"
allowed_web_cidr = "0.0.0.0/0"

# SSH Key - UPDATE THIS!
ssh_key_name = "spidy"

# Project
project_name = "aria2-downloader"
