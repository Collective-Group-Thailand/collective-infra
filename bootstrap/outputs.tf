output "state_bucket" {
  value = aws_s3_bucket.tfstate.bucket
}

output "github_oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.github.arn
}

output "gha_terraform_role_arn" {
  description = "Set as GitHub repo variable AWS_TERRAFORM_ROLE_ARN"
  value       = aws_iam_role.gha_terraform.arn
}

output "backend_hcl" {
  description = "Paste into envs/*/backend.hcl"
  value       = <<-EOT
    bucket       = "${aws_s3_bucket.tfstate.bucket}"
    region       = "${var.region}"
    encrypt      = true
    use_lockfile = true
  EOT
}
