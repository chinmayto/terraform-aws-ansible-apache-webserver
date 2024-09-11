################################################################################
# Create two VPC and components
################################################################################

module "vpc" {
  source                = "./modules/vpc"
  name                  = "VPC"
  aws_region            = var.aws_region
  vpc_cidr_block        = var.vpc_cidr_block_a #"10.1.0.0/16"
  public_subnets_cidrs  = [cidrsubnet(var.vpc_cidr_block_a, 8, 1)]
  private_subnets_cidrs = [cidrsubnet(var.vpc_cidr_block_a, 8, 2)]
  enable_dns_hostnames  = var.enable_dns_hostnames
  aws_azs               = var.aws_azs
  common_tags           = local.common_tags
  naming_prefix         = local.naming_prefix
}

################################################################################
# Create Ansible Control Node on EC2
################################################################################

module "ansible_control_node" {
  source           = "./modules/ansible_control_node"
  instance_type    = var.instance_type
  instance_key     = var.instance_key
  subnet_id        = module.vpc.public_subnets[0]
  vpc_id           = module.vpc.vpc_id
  ec2_name         = "Ansible Server"
  sg_ingress_ports = var.sg_ingress_control_node
  common_tags      = local.common_tags
  naming_prefix    = local.naming_prefix
}

################################################################################
# Create Managed Nodes for Webserver
################################################################################
module "webserver" {
  source        = "./modules/web"
  instance_type = var.instance_type
  instance_key  = var.webserver_key
  #subnet_id        = module.vpc.private_subnets[0]
  subnet_id        = module.vpc.public_subnets[0]
  vpc_id           = module.vpc.vpc_id
  ec2_name         = "Webserver"
  sg_ingress_ports = var.sg_ingress_managed_node
  common_tags      = local.common_tags
  naming_prefix    = local.naming_prefix
}

################################################################################
# Generate inventory.ini file with public IP of the managed nodes
################################################################################
data "template_file" "ansible_inventory" {
  template = file("${path.module}/inventory.tpl")
  vars = {
    instance_ip = join("\n", module.webserver.public_ip)
  }
}

resource "local_file" "ansible_inventory" {
  content  = data.template_file.ansible_inventory.rendered
  filename = "${path.module}/ansible/inventory.ini"
}


################################################################################
# Execute scripts on Ansible Control Node EC2 instance
################################################################################

resource "null_resource" "execute_script" {

  # Changes to any instance of the cluster requires re-provisioning
  triggers = {
    public_ip = join("\n", module.webserver.public_ip)
  }

  connection {
    host = module.ansible_control_node.public_ip
    type = "ssh"
    user = "ec2-user"
    private_key = file("F:/AWS/WorkshopKeyPair")
    timeout     = "4m"
  }

  provisioner "remote-exec" {
    inline = [
      "mkdir ansible",
    ]
    on_failure = continue
  }

  # Copy a directory
  provisioner "file" {
    source      = "ansible/"
    destination = "/home/ec2-user/ansible"
  }

  provisioner "file" {
    source      = "F:/AWS/ec2_keypair.pem"
    destination = "/home/ec2-user/ansible/ec2_keypair.pem"
  }

  provisioner "remote-exec" {
    inline = [
      "cd ansible",
      "chmod 600 /home/ec2-user/ansible/ec2_keypair.pem",
      "ansible-config init --disabled > ansible.cfg",
      "sed -i 's/host_key_checking=True/host_key_checking=False/g' ansible.cfg",
    ]
  }

  provisioner "remote-exec" {
    inline = [
      "cd ansible",
      "ansible-playbook -i inventory.ini --private-key ec2_keypair.pem add_to_ssh_known_hosts.yml -u ec2-user",
      "ansible webservers -m ping -i inventory.ini -u ec2-user --private-key ec2_keypair.pem",
      "ansible-playbook -i inventory.ini --private-key ec2_keypair.pem install_httpd.yml -u ec2-user",
    ]
  }
}
