output "vpc_id" {
  description = "The VPC's id."
  value       = aws_vpc.this.id
}

output "cidr_block" {
  description = "The VPC's address range. Consumed by peered stacks, which need it for their own route table entries and security group rules."
  value       = aws_vpc.this.cidr_block
}

output "private_subnet_ids" {
  description = "Private subnet ids, one per availability zone."
  value       = aws_subnet.private[*].id
}

output "public_subnet_ids" {
  description = "Public subnet ids, empty when the VPC is private throughout."
  value       = aws_subnet.public[*].id
}

output "private_route_table_id" {
  description = "The private route table. A peered stack adds a route to this table pointing at the peering connection."
  value       = aws_route_table.private.id
}

output "public_route_table_id" {
  description = "The public route table, or an empty string on a private-only VPC. This is where a return route to a peered VPC belongs when the resource being reached sits in the public subnets - as the RDS instance does."
  value       = try(aws_route_table.public[0].id, "")
}

output "availability_zones" {
  description = "The availability zones used, in the same order as the subnet lists."
  value       = local.azs
}
