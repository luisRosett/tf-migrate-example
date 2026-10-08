variable "aws_region" {
  description = "AWS region for the demo instance."
  type        = string
  default     = "eu-west-1"
}

variable "instance_type" {
  description = "Instance type. t3.micro keeps the demo cheap."
  type        = string
  default     = "t3.micro"
}

variable "instance_name" {
  description = "Name tag of the demo instance."
  type        = string
  default     = "hcp-tf-migration-demo"
}

variable "owner" {
  description = "Owner tag, useful when several people run the demo in one account."
  type        = string
  default     = "hashicorp-demo"
}
