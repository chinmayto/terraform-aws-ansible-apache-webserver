variable "common_tags" {}
variable "naming_prefix" {}
variable "instance_type" {}
variable "instance_key" {}

variable "subnet_id" {}
variable "ec2_name" {}
variable "vpc_id" {}

variable "sg_ingress_ports" {
  type = list(object({
    description = string
    port        = number
  }))
  default = [
    {
      description = "Allows HTTP traffic"
      port        = 80
    },
    {
      description = "Allows SSH traffic from Control Node"
      port        = 22
    },
  ]
}
