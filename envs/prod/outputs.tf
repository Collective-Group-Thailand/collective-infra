output "instance_id" {
  value = module.stack.instance_id
}

output "public_ip" {
  value = module.stack.public_ip
}

output "deploy_role_arn" {
  value = module.stack.deploy_role_arn
}

output "backup_bucket" {
  value = module.stack.backup_bucket
}

output "product_assets_buckets" {
  value = module.stack.product_assets_buckets
}

output "product_secret_names" {
  value = module.stack.product_secret_names
}

output "platform_secret_names" {
  value = module.stack.platform_secret_names
}

output "ses_dns_records" {
  value = module.stack.ses_dns_records
}

output "release_publisher_policy_arns" {
  value = module.stack.release_publisher_policy_arns
}
