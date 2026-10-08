###############################################################################
# HCP Terraform demo - "before" state
#
# This configuration is applied FIRST against the customer's own S3 backend,
# to simulate their current state management. It is then migrated to
# HCP Terraform without destroying or recreating anything.
###############################################################################

terraform {
  
  backend "s3" {
    bucket = "demo-state-bucket-main"
    key    = "terraform.tfstate"
    region = "us-west-2"
  }
  required_version = ">= 1.16.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Latest Amazon Linux 2023 AMI - avoids hardcoding an AMI id per region.
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

resource "aws_instance" "demo" {
  ami           = data.aws_ami.al2023.id
  instance_type = var.instance_type

  tags = {
    Name        = var.instance_name
    Environment = "demo"
    ManagedBy   = "terraform-local-state"
    Owner       = var.owner
  }
}

output "instance_id" {
  description = "EC2 instance id - must stay IDENTICAL before and after the migration."
  value       = aws_instance.demo.id
}

output "instance_private_ip" {
  value = aws_instance.demo.private_ip
}
