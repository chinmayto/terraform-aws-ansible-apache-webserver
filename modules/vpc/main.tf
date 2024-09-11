################################################################################
# Create the VPC
################################################################################
resource "aws_vpc" "app_vpc" {
  cidr_block           = var.vpc_cidr_block
  enable_dns_hostnames = var.enable_dns_hostnames

  tags = merge(var.common_tags, {
    Name = "${var.naming_prefix}-${var.name}"
  })
}

################################################################################
# Create the internet gateway
################################################################################
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.app_vpc.id

  tags = merge(var.common_tags, {
    Name = "${var.naming_prefix}-igw"
  })
}

################################################################################
# Create the public subnets
################################################################################
resource "aws_subnet" "public_subnets" {
  vpc_id = aws_vpc.app_vpc.id

  count             = length(var.public_subnets_cidrs)
  cidr_block        = element(var.public_subnets_cidrs, count.index)
  availability_zone = element(var.aws_azs, count.index)

  map_public_ip_on_launch = true # This makes public subnet

  tags = merge(var.common_tags, {
    Name = "${var.naming_prefix}-pubsubnet-${count.index + 1}"
  })
}

################################################################################
# Create the public route table
################################################################################
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.app_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = merge(var.common_tags, {
    Name = "${var.naming_prefix}-pub-rtable"
  })

}

################################################################################
# Assign the public route table to the public subnet
################################################################################
resource "aws_route_table_association" "public_rt_asso" {
  count          = length(var.public_subnets_cidrs)
  subnet_id      = element(aws_subnet.public_subnets[*].id, count.index)
  route_table_id = aws_route_table.public_rt.id
}
