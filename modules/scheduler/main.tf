# EventBridge Scheduler → EC2 StartInstances / StopInstances on a cron, in Asia/Bangkok. No Lambda.

data "aws_partition" "current" {}

data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "permissions" {
  statement {
    actions   = ["ec2:StartInstances", "ec2:StopInstances"]
    resources = [var.instance_arn]
  }
}

resource "aws_iam_role" "this" {
  name               = "${var.name}-scheduler"
  assume_role_policy = data.aws_iam_policy_document.trust.json
}

resource "aws_iam_role_policy" "this" {
  name   = "${var.name}-scheduler"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.permissions.json
}

resource "aws_scheduler_schedule_group" "this" {
  name = var.name
}

resource "aws_scheduler_schedule" "start" {
  name                         = "${var.name}-start"
  group_name                   = aws_scheduler_schedule_group.this.name
  description                  = "Start ${var.instance_id} (${var.start_cron} ${var.timezone})"
  schedule_expression          = "cron(${var.start_cron})"
  schedule_expression_timezone = var.timezone
  state                        = var.enabled ? "ENABLED" : "DISABLED"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:${data.aws_partition.current.partition}:scheduler:::aws-sdk:ec2:startInstances"
    role_arn = aws_iam_role.this.arn
    input    = jsonencode({ InstanceIds = [var.instance_id] })
    retry_policy {
      maximum_retry_attempts       = 3
      maximum_event_age_in_seconds = 900
    }
  }
}

resource "aws_scheduler_schedule" "stop" {
  name                         = "${var.name}-stop"
  group_name                   = aws_scheduler_schedule_group.this.name
  description                  = "Stop ${var.instance_id} (${var.stop_cron} ${var.timezone})"
  schedule_expression          = "cron(${var.stop_cron})"
  schedule_expression_timezone = var.timezone
  state                        = var.enabled ? "ENABLED" : "DISABLED"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:${data.aws_partition.current.partition}:scheduler:::aws-sdk:ec2:stopInstances"
    role_arn = aws_iam_role.this.arn
    input    = jsonencode({ InstanceIds = [var.instance_id] })
    retry_policy {
      maximum_retry_attempts       = 3
      maximum_event_age_in_seconds = 900
    }
  }
}
