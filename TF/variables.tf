variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "dev"
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for public subnet"
  type        = string
  default     = "10.0.1.0/24"
}

variable "availability_zone" {
  description = "Availability zone for subnet"
  type        = string
  default     = "us-east-1a"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.small"
}

variable "aria2_web_port" {
  description = "Port for aria2 web UI"
  type        = number
  default     = 8080
}

variable "aria2_rpc_port" {
  description = "Port for aria2 RPC"
  type        = number
  default     = 6800
}

variable "allowed_ssh_cidr" {
  description = "CIDR block allowed to SSH (your IP)"
  type        = string
  default     = "0.0.0.0/0"
}

variable "allowed_web_cidr" {
  description = "CIDR block allowed to access aria2 web UI"
  type        = string
  default     = "0.0.0.0/0"
}

variable "ssh_key_name" {
  description = "Name of existing AWS SSH key pair"
  type        = string
}

variable "project_name" {
  description = "Project name for resource naming"
  type        = string
  default     = "aria2-downloader"
}


variable "git_branch" {
  type        = string
  description = "Target Git branch to deploy on EC2"
  default     = "main"
}

variable "execution_mode" {
  type        = string
  default     = "both"
  description = "Execution mode: 'aria2', 'app', or 'both'"

  validation {
    condition     = contains(["aria2", "app", "both"], var.execution_mode)
    error_message = "The execution_mode must be 'aria2', 'app', or 'both'."
  }
}

variable "priority_app" {
  type        = string
  default     = "aria2"
  description = "When execution_mode is 'both', determines which app deploys first: 'aria2' (Docker/Aria2 first) or 'app' (Stream Grabber first)"

  validation {
    condition     = contains(["aria2", "app"], var.priority_app)
    error_message = "The priority_app must be 'aria2' or 'app'."
  }
}

# In variables.tf (or wherever your branch is defined)
variable "app_branch" {
  type        = string
  description = "Target Git branch to pull on EC2"
  default     = "main"
}

# In main.tf / data.tf: Fetch the commit SHA of that branch locally
data "external" "git_commit" {
  program = [
    "bash", "-c",
    "echo \"{\\\"commit\\\": \\\"$(git rev-parse ${var.app_branch})\\\", \\\"short_commit\\\": \\\"$(git rev-parse --short ${var.app_branch})\\\"}\""
  ]
}

