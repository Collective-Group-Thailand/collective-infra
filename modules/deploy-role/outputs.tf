output "role_arn" {
  description = "Set as GitHub Environment variable AWS_DEPLOY_ROLE_ARN"
  value       = aws_iam_role.this.arn
}
