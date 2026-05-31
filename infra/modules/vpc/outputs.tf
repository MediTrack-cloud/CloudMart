output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "private_app_subnet_ids" {
  value = aws_subnet.private_app[*].id
}

output "private_data_subnet_ids" {
  value = aws_subnet.private_data[*].id
}

output "alb_sg_id" {
  value = aws_security_group.alb.id
}

output "eks_nodes_sg_id" {
  value = aws_security_group.eks_nodes.id
}

output "rds_sg_id" {
  value = aws_security_group.rds.id
}

output "bastion_sg_id" {
  value = aws_security_group.bastion.id
}

output "vpc_cidr" {
  value = aws_vpc.main.cidr_block
}
