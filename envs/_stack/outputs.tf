output "instance_id" {
  value = module.app_server.instance_id
}

output "public_ip" {
  description = "Elastic IP → create A records for every product hostname + platform_hostname"
  value       = module.app_server.public_ip
}

output "deploy_role_arn" {
  description = "GitHub Environment variable AWS_DEPLOY_ROLE_ARN"
  value       = module.deploy_role.role_arn
}

output "backup_bucket" {
  value = aws_s3_bucket.backups.bucket
}

output "product_assets_buckets" {
  value = { for k, p in module.product : k => p.assets_bucket }
}

output "product_secret_names" {
  value = { for k, p in module.product : k => p.secret_name }
}

output "platform_secret_names" {
  value = [for s in aws_secretsmanager_secret.platform : s.name]
}

output "ses_dns_records" {
  description = "Records to add at the registrar for products without route53_zone_id"
  value       = { for k, p in module.product : k => p.ses_dns_records if length(p.ses_dns_records) > 0 }
}

output "alerts_topic_arn" {
  value = module.app_server.alerts_topic_arn
}

output "release_publisher_policy_arns" {
  description = "Per product with release_prefixes: the policy a release engineer needs to upload artefacts"
  value       = { for k, p in module.product : k => p.release_publisher_policy_arn if p.release_publisher_policy_arn != null }
}
