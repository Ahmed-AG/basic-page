provider "aws" {
  region  = "us-east-1"
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "users" {
  description = "List of user emails"
  type        = list(string)
  default     = [
    "user1@example.com", "user2@example.com"
    ]
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t2.micro"
}

variable "ami_id" {
  description = "AMI ID for EC2 instances"
  type        = string
  default     = "ami-04b4f1a9cf54c11d0"
}

# Convert email addresses into valid key names (replace @ and .)
locals {
  sanitized_users = [for user in var.users : replace(replace(user, "@", "-at-"), ".", "-dot-")]
}


# Create VPC
resource "aws_vpc" "CNAPP_Training_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "CNAPP-Training-VPC"
  }
}

# Create Subnet
resource "aws_subnet" "CNAPP_Training_subnet" {
  vpc_id                  = aws_vpc.CNAPP_Training_vpc.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = data.aws_availability_zones.available.names[0]

  tags = {
    Name = "CNAPP-Training-Subnet"
  }
}

# Get Availability Zones
data "aws_availability_zones" "available" {}

# Create Internet Gateway
resource "aws_internet_gateway" "CNAPP_Training_gw" {
  vpc_id = aws_vpc.CNAPP_Training_vpc.id

  tags = {
    Name = "CNAPP-Training-InternetGateway"
  }
}

# Route Table
resource "aws_route_table" "CNAPP_Training_rt" {
  vpc_id = aws_vpc.CNAPP_Training_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.CNAPP_Training_gw.id
  }

  tags = {
    Name = "CNAPP-Training-RouteTable"
  }
}

# Associate Route Table with Subnet
resource "aws_route_table_association" "CNAPP_Training_rta" {
  subnet_id      = aws_subnet.CNAPP_Training_subnet.id
  route_table_id = aws_route_table.CNAPP_Training_rt.id
}

# Security Group (Allow SSH & HTTP)
resource "aws_security_group" "CNAPP_Training_sg" {
  vpc_id = aws_vpc.CNAPP_Training_vpc.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Allow SSH from anywhere (CHANGE for security)
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Allow HTTP access from anywhere
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "CNAPP-Training-SecurityGroup"
  }
}

# Create a unique SSH Key Pair for each user (Key names match email identifiers)
resource "tls_private_key" "CNAPP_Training_key" {
  count      = length(var.users)
  algorithm  = "RSA"
  rsa_bits   = 4096
}

resource "aws_key_pair" "CNAPP_Training_keypair" {
  count      = length(var.users)
  key_name   = "CNAPP-Key-${local.sanitized_users[count.index]}"
  public_key = tls_private_key.CNAPP_Training_key[count.index].public_key_openssh
}

# 🔹 Save the Private Key Locally (Named After the User)
resource "local_file" "CNAPP_Training_private_key" {
  count    = length(var.users)
  content  = tls_private_key.CNAPP_Training_key[count.index].private_key_pem
  filename = "${path.module}/CNAPP-Key-${local.sanitized_users[count.index]}.pem"
  file_permission = "0600"
}

# Create Multiple EC2 Instances (One per User)
resource "aws_instance" "CNAPP_Training_instances" {
  count                  = length(var.users)
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.CNAPP_Training_subnet.id
  vpc_security_group_ids = [aws_security_group.CNAPP_Training_sg.id]
  key_name               = aws_key_pair.CNAPP_Training_keypair[count.index].key_name
  associate_public_ip_address = true

  tags = {
    Name  = "CNAPP-Instance-${local.sanitized_users[count.index]}"
    Owner = var.users[count.index] # Assign the user email to the instance tag
  }
}

# Output Public IP Addresses of Instances
output "CNAPP_Training_instance_public_ips" {
  description = "Public IPs of the instances"
  value       = aws_instance.CNAPP_Training_instances[*].public_ip
}

# Output SSH Key Paths (Names Correspond to User Emails)
output "CNAPP_Training_private_key_paths" {
  description = "Paths to the SSH private keys for each instance"
  value       = local_file.CNAPP_Training_private_key[*].filename
}

# 🔹 Output SSH Commands for Each User
output "CNAPP_Training_ssh_instructions" {
  description = "Instructions to SSH into the instances"
  value = [
    for idx, ip in aws_instance.CNAPP_Training_instances[*].public_ip :
    "ssh -i CNAPP-Key-${local.sanitized_users[idx]}.pem ubuntu@${ip}"
  ]
}
