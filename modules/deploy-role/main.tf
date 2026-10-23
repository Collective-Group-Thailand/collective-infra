# IAM role that GitHub Actions (product repos + collective-infra) assumes via OIDC to deploy to ONE
# environment: push images to ECR, run SSM commands on the env's instance, start the UAT box.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id
  # Only workflows running in the matching GitHub Environment (e.g. "uat" / "production") may assume this role.
  # Classic subject, plus GitHub's immutable form (org/repo pinned by id; repo ids vary, the org id does not).
  subjects = concat(
    [for r in var.github_repos : "repo:${var.github_org}/${r}:environment:${var.github_environment}"],
    var.github_org_id == null ? [] : [for r in var.github_repos : "repo:${var.github_org}@${var.github_org_id}/${r}@*:environment:${var.github_environment}"],
  )
}

data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.github_oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.subjects
    }
  }
}

resource "aws_iam_role" "this" {
  name                 = "${var.name}-gha-deploy"
  description          = "GitHub Actions deploy role for ${var.environment}"
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "permissions" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid = "EcrPush"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
    ]
    resources = var.ecr_repository_arns
  }

  # Run the deploy script on the environment's box only
  statement {
    sid       = "SsmSendToInstance"
    actions   = ["ssm:SendCommand"]
    resources = [var.instance_arn]
  }
  statement {
    sid       = "SsmSendDocument"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:${local.partition}:ssm:${var.region}::document/AWS-RunShellScript"]
  }
  statement {
    sid       = "SsmReadResults"
    actions   = ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations", "ssm:ListCommands", "ssm:DescribeInstanceInformation"]
    resources = ["*"]
  }

  statement {
    sid       = "DescribeInstances"
    actions   = ["ec2:DescribeInstances", "ec2:DescribeInstanceStatus"]
    resources = ["*"]
  }

  dynamic "statement" {
    for_each = var.allow_start_instance ? [1] : []
    content {
      sid       = "StartInstanceForDeploy"
      actions   = ["ec2:StartInstances"]
      resources = [var.instance_arn]
    }
  }
}

resource "aws_iam_role_policy" "this" {
  name   = "${var.name}-gha-deploy"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.permissions.json
}
