output "instance_id" {
  value = aws_instance.ansible_control_node.id
}

output "security_group_id" {
  value = aws_security_group.ansible_control_node_sg.id
}

output "public_ip" {
  value = aws_instance.ansible_control_node.public_ip
}