################################################################################
# Get latest Amazon Linux 2023 AMI
################################################################################
data "aws_ami" "amazon-linux-2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

################################################################################
# Create the security group for Ansible Controle Node EC2
################################################################################
resource "aws_security_group" "ansible_control_node_sg" {
  description = "Allow traffic for EC2"
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = var.sg_ingress_ports
    iterator = sg_ingress

    content {
      description = sg_ingress.value["description"]
      from_port   = sg_ingress.value["port"]
      to_port     = sg_ingress.value["port"]
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.common_tags, {
    Name = "${var.naming_prefix}-control-node-sg"
  })
}

################################################################################
# Create the Linux EC2 instance with ansible installation
################################################################################
resource "aws_instance" "ansible_control_node" {
  ami                    = data.aws_ami.amazon-linux-2023.id
  instance_type          = var.instance_type
  key_name               = var.instance_key
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.ansible_control_node_sg.id]

  user_data = <<-EOF
  #!/bin/bash
  sudo yum update -y

  sudo amazon-linux-extras install epel
  sudo yum install -y ansible

  ansible —version
EOF

  tags = merge(var.common_tags, {
    Name = "${var.ec2_name}"
  })
}