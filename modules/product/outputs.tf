output "assets_bucket" {
  value = aws_s3_bucket.assets.bucket
}

output "assets_bucket_arn" {
  value = aws_s3_bucket.assets.arn
}

output "secret_arn" {
  value = aws_secretsmanager_secret.app.arn
}

output "secret_name" {
  value = aws_secretsmanager_secret.app.name
}

output "policy_arn" {
  value = aws_iam_policy.product.arn
}

output "release_publisher_policy_arn" {
  description = "Attach to the release engineer's identity (null when the product has no release_prefixes)"
  value       = length(aws_iam_policy.release_publisher) > 0 ? aws_iam_policy.release_publisher[0].arn : null
}

output "ses_dns_records" {
  description = "DNS records to create at the registrar when route53_zone_id is not set"
  value = var.ses_domain == null ? [] : concat(
    [for t in aws_sesv2_email_identity.domain[0].dkim_signing_attributes[0].tokens :
      { name = "${t}._domainkey.${var.ses_domain}", type = "CNAME", value = "${t}.dkim.amazonses.com" }
    ],
    [
      { name = "mail.${var.ses_domain}", type = "MX", value = "10 feedback-smtp.${var.region}.amazonses.com" },
      { name = "mail.${var.ses_domain}", type = "TXT", value = "v=spf1 include:amazonses.com -all" },
      { name = "_dmarc.${var.ses_domain}", type = "TXT", value = "v=DMARC1; p=quarantine; rua=mailto:dmarc@${var.ses_domain}; adkim=s; aspf=s" },
    ]
  )
}
