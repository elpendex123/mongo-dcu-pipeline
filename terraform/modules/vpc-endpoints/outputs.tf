output "security_group_id" {
  description = "The endpoints' security group."
  value       = aws_security_group.endpoints.id
}

output "interface_endpoint_ids" {
  description = "Map of service name to endpoint id."
  value       = { for k, v in aws_vpc_endpoint.interface : k => v.id }
}

output "s3_endpoint_id" {
  description = "The S3 gateway endpoint."
  value       = aws_vpc_endpoint.s3.id
}

output "hourly_cost_estimate" {
  description = "Approximate USD per hour for the interface endpoints: count x availability zones x $0.01. The S3 gateway endpoint is free and is not counted."
  value       = length(var.interface_services) * var.interface_endpoint_azs * 0.01
}
