# Configuring Apache Web Servers on EC2 Instances Using Ansible and Terraform

In this blog post, we will walk through how to configure a set of EC2 Apache web servers using Ansible for configuration management, and Terraform for automating the infrastructure provisioning.

### Why Use Ansible?
Ansible is an open-source automation tool that simplifies configuration management, application deployment, and orchestration tasks. It is agentless, meaning you don't need to install any software on the target machines to manage them. Instead, it relies on SSH to connect to remote systems, making it a lightweight solution. Ansible uses playbooks—YAML files that define a series of automation steps—to execute tasks, ensuring that systems are configured in a desired state.

Ansible is ideal for tasks such as:
1. Configuring multiple servers at scale.
2. Deploying applications consistently across environments.
3. Automating repetitive IT tasks like updates and system installations.

By integrating Terraform and Ansible, we can automate both the provisioning of infrastructure and the configuration of the services running on it.

## Architecture
Before we get started, let's take a quick look at the architecture we'll be working with:

![alt text](/images/diagram.png)

## Step 1: Creating the VPC and Network Components
We set up the underlying network infrastructure having a VPC, Public Subnets, Internet Gateway and Route Table. We are not complicating the strcutre as our main focus in this post is to understand and use Ansible for configuration management. (Refer to GitHub Repo!)

## Step 2: Creating a Single Ansible Control Node
Create an EC2 instance that will act as the Ansible control node. This node will have ansible installed using user data and run the Ansible playbooks to configure the web servers. Security group for ansible control node will allow only incoming SSH access.

```terraform
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
```
## Step 3: Creating 3 EC2 Instances as Managed Nodes
Next, we’ll create three EC2 instances that will act as our managed nodes (the web servers). These instances will have the a common Security Group allowing HTTP and SSH access and public IPs. We will not install anything with userdata here!

```terraform
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
# Create the security group for EC2
################################################################################
resource "aws_security_group" "security_group" {
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
    Name = "${var.naming_prefix}-webserver-sg"
  })
}


################################################################################
# Create the Linux EC2 instance with a website
################################################################################
resource "aws_instance" "web" {
  count                  = 3
  ami                    = data.aws_ami.amazon-linux-2023.id
  instance_type          = var.instance_type
  key_name               = var.instance_key
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.security_group.id]

  tags = merge(var.common_tags, {
    Name = "${var.ec2_name}-${count.index}"
  })
}
```
## Step 4: Generate inventory file by getting IP addresses of managed nodes
Next, we will generate inventory file with IP addresses of managed EC2 nodes.
```terraform
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
```

## Step 5: Building the Ansible Directory and Applying Playbooks
Now that the EC2 instances are up and running, we can configure them using Ansible. We will build the Ansible directory structure and upload the required files.
I have used remote-exec provisioners to perform this tasks just to explanation, but ideally those should be used as last resort. Ansible control node will ideally be always ready and available in real world scenario.

1. Upload Playbooks to the Ansible Directory

First, create the `ansible` directory on the control node
```shell
mkdir ansible
```
and upload ansible playbooks, invenotry file and EC2 key pairs to this directory using `file` provisioners

2. Generate and update `ansible.cfg` to Disable Host Key Checking
To prevent SSH errors when connecting to the managed nodes, we’ll modify `ansible.cfg` to disable host key checking:
```conf
[defaults]
host_key_checking = False
```

3. Apply Ansible Playbook to Add Hosts to SSH Known Hosts
Before running other tasks, we’ll ensure that the control node adds the managed nodes to the `known_hosts` file. 

(Either disable host checking or add hosts to known_hosts file, second way is more secure way!)

Create a playbook add_known_hosts.yml:
```yml
---
- name: Gather facts from 'webservers' hosts in inventory
  hosts: webservers
  vars:
    ansible_host_key_checking: false
    ansible_ssh_extra_args: '-o UserKnownHostsFile=/dev/null'
  tasks:
    - name: Get network info
      ansible.builtin.setup:
        gather_subset: network

- name: Add public keys to known_hosts file
  hosts: localhost
  connection: local
  vars:
    ssh_known_hosts_file: "{{ lookup('env','HOME') + '/.ssh/known_hosts' }}"
    ssh_known_hosts: "{{ groups['webservers'] }}"
  tasks:
    - name: Add to known_hosts
      ansible.builtin.known_hosts:
        path: '{{ ssh_known_hosts_file }}'
        name: '{{ item }}'
        key: "{{ lookup('pipe', 'ssh-keyscan {{ item }}') }}"
        state: present
      with_items: '{{ ssh_known_hosts }}'
      become: false
```
Command to run this playbook:

```shell
cd ansible
ansible-playbook -i inventory.ini --private-key ec2_keypair.pem add_to_ssh_known_hosts.yml -u ec2-user
```

4. Apply Ansible Playbook to Install and Start Apache (httpd)

Finally, we’ll apply a playbook to install and start the Apache HTTP server on all managed nodes. I have used list of commands to build index.html file.
Otherwise, we can install git on managed nodes and clone the git repo with a full fleged website pages.

```yml
---
- name: installing httpd
  hosts: webservers
  become: true
  tasks: 
    - name: installing httpd package 
      yum: 
        name: httpd
        state: installed
      notify: start httpd service
    
    - name: modify home page
      shell: |
        TOKEN=$(curl --request PUT "http://169.254.169.254/latest/api/token" --header "X-aws-ec2-metadata-token-ttl-seconds: 3600")

        instanceId=$(curl -s http://169.254.169.254/latest/meta-data/instance-id --header "X-aws-ec2-metadata-token: $TOKEN")
        instanceAZ=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone --header "X-aws-ec2-metadata-token: $TOKEN")
        pubHostName=$(curl http://169.254.169.254/latest/meta-data/public-hostname --header "X-aws-ec2-metadata-token: $TOKEN")
        pubIPv4=$(curl http://169.254.169.254/latest/meta-data/public-ipv4 --header "X-aws-ec2-metadata-token: $TOKEN")
        privHostName=$(curl -s http://169.254.169.254/latest/meta-data/local-hostname --header "X-aws-ec2-metadata-token: $TOKEN")
        privIPv4=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4 --header "X-aws-ec2-metadata-token: $TOKEN")
        
        echo "<font face = "Verdana" size = "5">"                               > /var/www/html/index.html
        echo "<center><h1>EC2 Apache Webserver configured with Ansible!</h1></center>"   >> /var/www/html/index.html
        echo "<center> <b>EC2 Instance Metadata</b> </center>"                  >> /var/www/html/index.html
        echo "<center> <b>Instance ID:</b> $instanceId </center>"               >> /var/www/html/index.html
        echo "<center> <b>AWS Availablity Zone:</b> $instanceAZ </center>"      >> /var/www/html/index.html
        echo "<center> <b>Public Hostname:</b> $pubHostName </center>"          >> /var/www/html/index.html
        echo "<center> <b>Public IPv4:</b> $pubIPv4 </center>"                  >> /var/www/html/index.html

        echo "<center> <b>Private Hostname:</b> $privHostName </center>"        >> /var/www/html/index.html
        echo "<center> <b>Private IPv4:</b> $privIPv4 </center>"                >> /var/www/html/index.html
        echo "</font>"                                                          >> /var/www/html/index.html

  handlers:   
  - name: start httpd service
    service:
      name: httpd
      state: started
```

command to run this playbook:
```shell
ansible-playbook -i inventory.ini --private-key ec2_keypair.pem install_httpd.yml -u ec2-user
```
(I have used ansible ping command just to show the reachablity of managed nodes from control node)


We will apply above steps using a terraform null_resource which will run file and remote-exes provisioners to do the tasks!

```terraform
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
```
## Steps to Run Terraform
Follow these steps to execute the Terraform configuration:
```terraform
terraform init
terraform plan 
terraform apply -auto-approve
```

Upon successful completion, Terraform will provide relevant outputs.
```terraform
Apply complete! Resources: 13 added, 0 changed, 0 destroyed.
```

Apply command will show the logs how how ansible runs playbooks on all managed nodes
```ansible
null_resource.execute_script: Provisioning with 'remote-exec'...
null_resource.execute_script (remote-exec): Connecting to remote host via SSH...
null_resource.execute_script (remote-exec):   Host: 44.206.231.153
null_resource.execute_script (remote-exec):   User: ec2-user
null_resource.execute_script (remote-exec):   Password: false
null_resource.execute_script (remote-exec):   Private key: true
null_resource.execute_script (remote-exec):   Certificate: false
null_resource.execute_script (remote-exec):   SSH Agent: false
null_resource.execute_script (remote-exec):   Checking Host Key: false
null_resource.execute_script (remote-exec):   Target Platform: unix
local_file.ansible_inventory: Creating...
local_file.ansible_inventory: Creation complete after 0s [id=3538bfad51a79766d4ee78be10da390a463d93f3]
null_resource.execute_script (remote-exec): Connected!
null_resource.execute_script: Still creating... [10s elapsed]
null_resource.execute_script: Provisioning with 'file'...
null_resource.execute_script: Still creating... [20s elapsed]
null_resource.execute_script: Provisioning with 'file'...
null_resource.execute_script: Still creating... [30s elapsed]
null_resource.execute_script: Provisioning with 'remote-exec'...
null_resource.execute_script (remote-exec): Connecting to remote host via SSH...
null_resource.execute_script (remote-exec):   Host: 44.206.231.153
null_resource.execute_script (remote-exec):   User: ec2-user
null_resource.execute_script (remote-exec):   Password: false
null_resource.execute_script (remote-exec):   Private key: true
null_resource.execute_script (remote-exec):   Certificate: false
null_resource.execute_script (remote-exec):   SSH Agent: false
null_resource.execute_script (remote-exec):   Checking Host Key: false
null_resource.execute_script (remote-exec):   Target Platform: unix
null_resource.execute_script: Still creating... [40s elapsed]
null_resource.execute_script (remote-exec): Connected!
null_resource.execute_script: Still creating... [50s elapsed]
null_resource.execute_script: Provisioning with 'remote-exec'...
null_resource.execute_script (remote-exec): Connecting to remote host via SSH...
null_resource.execute_script (remote-exec):   Host: 44.206.231.153
null_resource.execute_script (remote-exec):   User: ec2-user
null_resource.execute_script (remote-exec):   Password: false
null_resource.execute_script (remote-exec):   Private key: true
null_resource.execute_script (remote-exec):   Certificate: false
null_resource.execute_script (remote-exec):   SSH Agent: false
null_resource.execute_script (remote-exec):   Checking Host Key: false
null_resource.execute_script (remote-exec):   Target Platform: unix
null_resource.execute_script (remote-exec): Connected!
null_resource.execute_script: Still creating... [1m0s elapsed]

null_resource.execute_script (remote-exec): PLAY [Gather facts from 'webservers' hosts in inventory] ***********************

null_resource.execute_script (remote-exec): TASK [Gathering Facts] *********************************************************
null_resource.execute_script (remote-exec): [WARNING]: Platform linux on host 35.174.165.128 is using the discovered Python
null_resource.execute_script (remote-exec): interpreter at /usr/bin/python3.9, but future installation of another Python
null_resource.execute_script (remote-exec): interpreter could change the meaning of that path. See
null_resource.execute_script (remote-exec): https://docs.ansible.com/ansible-
null_resource.execute_script (remote-exec): core/2.15/reference_appendices/interpreter_discovery.html for more information.
null_resource.execute_script (remote-exec): ok: [35.174.165.128]
null_resource.execute_script (remote-exec): [WARNING]: Platform linux on host 3.82.227.89 is using the discovered Python
null_resource.execute_script (remote-exec): interpreter at /usr/bin/python3.9, but future installation of another Python
null_resource.execute_script (remote-exec): interpreter could change the meaning of that path. See
null_resource.execute_script (remote-exec): https://docs.ansible.com/ansible-
null_resource.execute_script (remote-exec): core/2.15/reference_appendices/interpreter_discovery.html for more information.
null_resource.execute_script (remote-exec): ok: [3.82.227.89]
null_resource.execute_script (remote-exec): [WARNING]: Platform linux on host 3.86.227.74 is using the discovered Python
null_resource.execute_script (remote-exec): interpreter at /usr/bin/python3.9, but future installation of another Python
null_resource.execute_script (remote-exec): interpreter could change the meaning of that path. See
null_resource.execute_script (remote-exec): https://docs.ansible.com/ansible-
null_resource.execute_script (remote-exec): core/2.15/reference_appendices/interpreter_discovery.html for more information.
null_resource.execute_script (remote-exec): ok: [3.86.227.74]

null_resource.execute_script (remote-exec): TASK [Get network info] ********************************************************
null_resource.execute_script (remote-exec): ok: [35.174.165.128]
null_resource.execute_script (remote-exec): ok: [3.86.227.74]
null_resource.execute_script (remote-exec): ok: [3.82.227.89]

null_resource.execute_script (remote-exec): PLAY [Add public keys to known_hosts file] *************************************

null_resource.execute_script (remote-exec): TASK [Gathering Facts] *********************************************************
null_resource.execute_script (remote-exec): ok: [localhost]

null_resource.execute_script (remote-exec): TASK [Add to known_hosts] ******************************************************
null_resource.execute_script (remote-exec): # 35.174.165.128:22 SSH-2.0-OpenSSH_8.7
null_resource.execute_script (remote-exec): # 35.174.165.128:22 SSH-2.0-OpenSSH_8.7
null_resource.execute_script (remote-exec): # 35.174.165.128:22 SSH-2.0-OpenSSH_8.7
null_resource.execute_script (remote-exec): # 35.174.165.128:22 SSH-2.0-OpenSSH_8.7
null_resource.execute_script (remote-exec): # 35.174.165.128:22 SSH-2.0-OpenSSH_8.7
null_resource.execute_script (remote-exec): changed: [localhost] => (item=35.174.165.128)
null_resource.execute_script (remote-exec): # 3.86.227.74:22 SSH-2.0-OpenSSH_8.7
null_resource.execute_script (remote-exec): # 3.86.227.74:22 SSH-2.0-OpenSSH_8.7
null_resource.execute_script (remote-exec): # 3.86.227.74:22 SSH-2.0-OpenSSH_8.7
null_resource.execute_script (remote-exec): # 3.86.227.74:22 SSH-2.0-OpenSSH_8.7
null_resource.execute_script (remote-exec): # 3.86.227.74:22 SSH-2.0-OpenSSH_8.7
null_resource.execute_script (remote-exec): changed: [localhost] => (item=3.86.227.74)
null_resource.execute_script (remote-exec): # 3.82.227.89:22 SSH-2.0-OpenSSH_8.7
null_resource.execute_script (remote-exec): # 3.82.227.89:22 SSH-2.0-OpenSSH_8.7
null_resource.execute_script (remote-exec): # 3.82.227.89:22 SSH-2.0-OpenSSH_8.7
null_resource.execute_script (remote-exec): # 3.82.227.89:22 SSH-2.0-OpenSSH_8.7
null_resource.execute_script (remote-exec): # 3.82.227.89:22 SSH-2.0-OpenSSH_8.7
null_resource.execute_script (remote-exec): changed: [localhost] => (item=3.82.227.89)

null_resource.execute_script (remote-exec): PLAY RECAP *********************************************************************
null_resource.execute_script (remote-exec): 3.82.227.89                : ok=2    changed=0    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0 
null_resource.execute_script (remote-exec): 3.86.227.74                : ok=2    changed=0    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0 
null_resource.execute_script (remote-exec): 35.174.165.128             : ok=2    changed=0    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0 
null_resource.execute_script (remote-exec): localhost                  : ok=2    changed=1    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0 

null_resource.execute_script (remote-exec): [WARNING]: Platform linux on host 35.174.165.128 is using the discovered Python
null_resource.execute_script (remote-exec): interpreter at /usr/bin/python3.9, but future installation of another Python
null_resource.execute_script (remote-exec): interpreter could change the meaning of that path. See
null_resource.execute_script (remote-exec): https://docs.ansible.com/ansible-
null_resource.execute_script (remote-exec): core/2.15/reference_appendices/interpreter_discovery.html for more information.
null_resource.execute_script (remote-exec): 35.174.165.128 | SUCCESS => {
null_resource.execute_script (remote-exec):     "ansible_facts": {
null_resource.execute_script (remote-exec):         "discovered_interpreter_python": "/usr/bin/python3.9"
null_resource.execute_script (remote-exec):     },
null_resource.execute_script (remote-exec):     "changed": false,
null_resource.execute_script (remote-exec):     "ping": "pong"
null_resource.execute_script (remote-exec): }
null_resource.execute_script (remote-exec): [WARNING]: Platform linux on host 3.86.227.74 is using the discovered Python
null_resource.execute_script (remote-exec): interpreter at /usr/bin/python3.9, but future installation of another Python
null_resource.execute_script (remote-exec): interpreter could change the meaning of that path. See
null_resource.execute_script (remote-exec): https://docs.ansible.com/ansible-
null_resource.execute_script (remote-exec): core/2.15/reference_appendices/interpreter_discovery.html for more information.
null_resource.execute_script (remote-exec): 3.86.227.74 | SUCCESS => {
null_resource.execute_script (remote-exec):     "ansible_facts": {
null_resource.execute_script (remote-exec):         "discovered_interpreter_python": "/usr/bin/python3.9"
null_resource.execute_script (remote-exec):     },
null_resource.execute_script (remote-exec):     "changed": false,
null_resource.execute_script (remote-exec):     "ping": "pong"
null_resource.execute_script (remote-exec): }
null_resource.execute_script (remote-exec): [WARNING]: Platform linux on host 3.82.227.89 is using the discovered Python
null_resource.execute_script (remote-exec): interpreter at /usr/bin/python3.9, but future installation of another Python
null_resource.execute_script (remote-exec): interpreter could change the meaning of that path. See
null_resource.execute_script (remote-exec): https://docs.ansible.com/ansible-
null_resource.execute_script (remote-exec): core/2.15/reference_appendices/interpreter_discovery.html for more information.
null_resource.execute_script (remote-exec): 3.82.227.89 | SUCCESS => {
null_resource.execute_script (remote-exec):     "ansible_facts": {
null_resource.execute_script (remote-exec):         "discovered_interpreter_python": "/usr/bin/python3.9"
null_resource.execute_script (remote-exec):     },
null_resource.execute_script (remote-exec):     "changed": false,
null_resource.execute_script (remote-exec):     "ping": "pong"
null_resource.execute_script (remote-exec): }

null_resource.execute_script (remote-exec): PLAY [installing httpd] ********************************************************

null_resource.execute_script (remote-exec): TASK [Gathering Facts] *********************************************************
null_resource.execute_script (remote-exec): [WARNING]: Platform linux on host 3.86.227.74 is using the discovered Python
null_resource.execute_script (remote-exec): interpreter at /usr/bin/python3.9, but future installation of another Python
null_resource.execute_script (remote-exec): interpreter could change the meaning of that path. See
null_resource.execute_script (remote-exec): https://docs.ansible.com/ansible-
null_resource.execute_script (remote-exec): core/2.15/reference_appendices/interpreter_discovery.html for more information.
null_resource.execute_script: Still creating... [1m10s elapsed]
null_resource.execute_script (remote-exec): ok: [3.86.227.74]
null_resource.execute_script (remote-exec): [WARNING]: Platform linux on host 3.82.227.89 is using the discovered Python
null_resource.execute_script (remote-exec): interpreter at /usr/bin/python3.9, but future installation of another Python
null_resource.execute_script (remote-exec): interpreter could change the meaning of that path. See
null_resource.execute_script (remote-exec): https://docs.ansible.com/ansible-
null_resource.execute_script (remote-exec): core/2.15/reference_appendices/interpreter_discovery.html for more information.
null_resource.execute_script (remote-exec): ok: [3.82.227.89]
null_resource.execute_script (remote-exec): [WARNING]: Platform linux on host 35.174.165.128 is using the discovered Python
null_resource.execute_script (remote-exec): interpreter at /usr/bin/python3.9, but future installation of another Python
null_resource.execute_script (remote-exec): interpreter could change the meaning of that path. See
null_resource.execute_script (remote-exec): https://docs.ansible.com/ansible-
null_resource.execute_script (remote-exec): core/2.15/reference_appendices/interpreter_discovery.html for more information.
null_resource.execute_script (remote-exec): ok: [35.174.165.128]

null_resource.execute_script (remote-exec): TASK [installing httpd package] ************************************************
null_resource.execute_script (remote-exec): changed: [3.82.227.89]
null_resource.execute_script (remote-exec): changed: [3.86.227.74]
null_resource.execute_script (remote-exec): changed: [35.174.165.128]

null_resource.execute_script (remote-exec): TASK [modify home page] ********************************************************
null_resource.execute_script (remote-exec): changed: [35.174.165.128]
null_resource.execute_script (remote-exec): changed: [3.86.227.74]
null_resource.execute_script (remote-exec): changed: [3.82.227.89]

null_resource.execute_script (remote-exec): RUNNING HANDLER [start httpd service] ******************************************
null_resource.execute_script (remote-exec): changed: [35.174.165.128]
null_resource.execute_script (remote-exec): changed: [3.86.227.74]
null_resource.execute_script (remote-exec): changed: [3.82.227.89]

null_resource.execute_script (remote-exec): PLAY RECAP *********************************************************************
null_resource.execute_script (remote-exec): 3.82.227.89                : ok=4    changed=3    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0
null_resource.execute_script (remote-exec): 3.86.227.74                : ok=4    changed=3    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0
null_resource.execute_script (remote-exec): 35.174.165.128             : ok=4    changed=3    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0

null_resource.execute_script: Creation complete after 1m18s [id=536435964]

Apply complete! Resources: 13 added, 0 changed, 0 destroyed.
```

## Testing

Ansible Control Node (Ansible Server) and Managed nodes (Webserver-0/1/2)

![alt text](/images/control_node.png)

Ansible Installed on Ansible Control Node

![alt text](/images/ansible_version.png)

Ansible Directory Structure

![alt text](/images/ansible_dir.png)

Inventory file

![alt text](/images/inventory.png)

known_hosts

![alt text](/images/known_hosts.png)

Webservers Configured using Ansible

![alt text](/images/webserver1.png)

![alt text](/images/webserver2.png)

![alt text](/images/webserver3.png)

## Cleanup
Remember to stop AWS components to avoid large bills.
```
terraform destroy -auto-approve
```

## Conclusion
In this post, we demonstrated how to provision a set of EC2 instances using Terraform and configure them as Apache web servers using Ansible. Terraform automated the infrastructure setup, while Ansible handled the configuration of the servers. By leveraging these two powerful tools, you can streamline both the infrastructure provisioning and configuration processes, making your deployments more efficient and reliable.

## Resources
GitHub Repo: https://github.com/chinmayto/terraform-aws-ansible-apache-webserver
