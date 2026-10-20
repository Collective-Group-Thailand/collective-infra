# One Graviton EC2 box running the Collective docker-compose platform.
# EIP + separate data EBS volume + SSM-only access + CloudWatch agent + alarms + auto-recovery + DLM snapshots.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# Latest Amazon Linux 2023 arm64 — pinned on first apply; `ami` is in ignore_changes so a new AMI
# never replaces the box silently (rotate deliberately with `terraform apply -replace`).
data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

locals {
  name       = "${var.name_prefix}-${var.environment}"
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  common_tags = {
    Environment = var.environment
  }
}

# --- IAM: instance role -------------------------------------------------------------------------
data "aws_iam_policy_document" "instance_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = "${local.name}-app-instance"
  assume_role_policy = data.aws_iam_policy_document.instance_trust.json
  tags               = local.common_tags
}

resource "aws_iam_instance_profile" "instance" {
  name = "${local.name}-app-instance"
  role = aws_iam_role.instance.name
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cw_agent" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/CloudWatchAgentServerPolicy"
}

data "aws_iam_policy_document" "instance_inline" {
  # Pull images from any ECR repo in this account
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid = "EcrPull"
    actions = [
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchCheckLayerAvailability",
      "ecr:DescribeImages",
    ]
    resources = ["arn:${local.partition}:ecr:*:${local.account_id}:repository/*"]
  }

  # pgBackRest + restore drills
  statement {
    sid       = "BackupBucketList"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [var.backup_bucket_arn]
  }
  statement {
    sid       = "BackupBucketObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]
    resources = ["${var.backup_bucket_arn}/*"]
  }

  # Platform-level secrets (deploy key, grafana, postgres superuser, valkey) — product secrets come via var.extra_policy_arns
  statement {
    sid       = "PlatformSecrets"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = ["arn:${local.partition}:secretsmanager:${var.region}:${local.account_id}:secret:${var.secrets_prefix}/platform/*"]
  }

  # CloudWatch agent config lives in SSM Parameter Store
  statement {
    sid       = "CwAgentConfig"
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.cw_agent_config.arn]
  }

  # Self-describe (bootstrap script reads its own tags / volume id)
  statement {
    sid       = "DescribeSelf"
    actions   = ["ec2:DescribeVolumes", "ec2:DescribeInstances", "ec2:DescribeTags"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "instance_inline" {
  name   = "${local.name}-app-instance-inline"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.instance_inline.json
}

resource "aws_iam_role_policy_attachment" "extra" {
  for_each   = toset(var.extra_policy_arns)
  role       = aws_iam_role.instance.name
  policy_arn = each.value
}

# --- CloudWatch agent config ---------------------------------------------------------------------
resource "aws_ssm_parameter" "cw_agent_config" {
  name        = "/${var.name_prefix}/${var.environment}/cloudwatch-agent"
  type        = "String"
  description = "Amazon CloudWatch agent config for the app server (memory + /data disk)"
  value = jsonencode({
    agent = { metrics_collection_interval = 60, run_as_user = "root" }
    metrics = {
      namespace         = "Collective/${var.environment}"
      append_dimensions = { InstanceId = "$${aws:InstanceId}" }
      aggregation_dimensions = [["InstanceId"], ["InstanceId", "path"]]
      metrics_collected = {
        mem  = { measurement = ["mem_used_percent"], metrics_collection_interval = 60 }
        swap = { measurement = ["swap_used_percent"], metrics_collection_interval = 60 }
        disk = {
          measurement                 = ["disk_used_percent"]
          resources                   = ["/", "/data"]
          metrics_collection_interval = 60
          ignore_file_system_types    = ["sysfs", "devtmpfs", "tmpfs", "overlay"]
        }
      }
    }
    logs = {
      logs_collected = {
        files = {
          collect_list = [
            {
              file_path       = "/var/log/cloud-init-output.log"
              log_group_name  = "/${var.name_prefix}/${var.environment}/cloud-init"
              log_stream_name = "{instance_id}"
              retention_in_days = 30
            },
            {
              file_path       = "/var/log/collective/*.log"
              log_group_name  = "/${var.name_prefix}/${var.environment}/platform"
              log_stream_name = "{instance_id}"
              retention_in_days = 30
            },
          ]
        }
      }
    }
  })
  tags = local.common_tags
}

# --- Data volume ---------------------------------------------------------------------------------
resource "aws_ebs_volume" "data" {
  availability_zone = var.availability_zone
  size              = var.data_volume_size_gb
  type              = "gp3"
  iops              = 3000
  throughput        = 125
  encrypted         = true
  final_snapshot    = true

  tags = merge(local.common_tags, {
    Name   = "${local.name}-data"
    Backup = "${local.name}-daily" # DLM target tag
  })

  lifecycle {
    prevent_destroy = true
  }
}

# --- Instance ------------------------------------------------------------------------------------
resource "aws_instance" "this" {
  ami                         = data.aws_ssm_parameter.al2023_arm64.value
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  availability_zone           = var.availability_zone
  vpc_security_group_ids      = [var.security_group_id]
  iam_instance_profile        = aws_iam_instance_profile.instance.name
  associate_public_ip_address = false # EIP below
  ebs_optimized               = true
  monitoring                  = false # detailed monitoring = +$2.10/mo per metric set; 5-min is fine here

  # T-family only ("standard" avoids surprise unlimited-credit charges; the credit alarm says when to move to m7g)
  dynamic "credit_specification" {
    for_each = startswith(var.instance_type, "t") ? [1] : []
    content {
      cpu_credits = var.cpu_credits
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 2          # containers need +1 hop to reach IMDS for the instance role
    instance_metadata_tags      = "enabled"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size_gb
    encrypted             = true
    delete_on_termination = true
    tags                  = merge(local.common_tags, { Name = "${local.name}-root" })
  }

  user_data = templatefile("${path.module}/templates/user-data.sh.tftpl", {
    environment       = var.environment
    region            = var.region
    account_id        = local.account_id
    name_prefix       = var.name_prefix
    secrets_prefix    = var.secrets_prefix
    backup_bucket     = var.backup_bucket_name
    data_volume_id    = replace(aws_ebs_volume.data.id, "-", "")
    cw_config_param   = aws_ssm_parameter.cw_agent_config.name
    github_org        = var.github_org
    infra_repo        = var.infra_repo
    infra_branch      = var.infra_branch
    compose_version   = var.compose_version
    platform_hostname = var.platform_hostname
  })
  user_data_replace_on_change = false

  tags = merge(local.common_tags, {
    Name = "${local.name}-app"
    Role = "app-server"
  })

  lifecycle {
    ignore_changes = [ami, user_data]
  }
}

resource "aws_volume_attachment" "data" {
  device_name                    = "/dev/sdf"
  volume_id                      = aws_ebs_volume.data.id
  instance_id                    = aws_instance.this.id
  stop_instance_before_detaching = true
}

resource "aws_eip" "this" {
  domain = "vpc"
  tags   = merge(local.common_tags, { Name = "${local.name}-app-eip" })
}

resource "aws_eip_association" "this" {
  instance_id   = aws_instance.this.id
  allocation_id = aws_eip.this.id
}

# --- Alerts: SNS ---------------------------------------------------------------------------------
resource "aws_sns_topic" "alerts" {
  name = "${local.name}-alerts"
  tags = local.common_tags
}

resource "aws_sns_topic_subscription" "email" {
  for_each  = toset(var.alert_emails)
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

# --- Alarms --------------------------------------------------------------------------------------
# Host-level failure → AWS recovers the instance onto new hardware (same id, EIP, EBS).
resource "aws_cloudwatch_metric_alarm" "system_check_recover" {
  alarm_name          = "${local.name}-app-system-check-failed"
  alarm_description   = "EC2 system status check failed for 2 periods → auto-recover"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_System"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { InstanceId = aws_instance.this.id }
  alarm_actions = [
    "arn:${local.partition}:automate:${var.region}:ec2:recover",
    aws_sns_topic.alerts.arn,
  ]
  tags = local.common_tags
}

# Guest OS hang → reboot (not for UAT, which is stopped on purpose outside hours)
resource "aws_cloudwatch_metric_alarm" "instance_check_reboot" {
  count               = var.enable_instance_check_reboot ? 1 : 0
  alarm_name          = "${local.name}-app-instance-check-failed"
  alarm_description   = "EC2 instance status check failed for 3 periods → reboot"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_Instance"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { InstanceId = aws_instance.this.id }
  alarm_actions = [
    "arn:${local.partition}:automate:${var.region}:ec2:reboot",
    aws_sns_topic.alerts.arn,
  ]
  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "cpu_credits" {
  alarm_name          = "${local.name}-app-cpu-credit-low"
  alarm_description   = "Burst credits running out — consider m7g (PLAN.md trigger)"
  namespace           = "AWS/EC2"
  metric_name         = "CPUCreditBalance"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = var.cpu_credit_threshold
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { InstanceId = aws_instance.this.id }
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  tags                = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "memory" {
  alarm_name          = "${local.name}-app-memory-high"
  alarm_description   = "mem_used_percent > ${var.memory_alarm_percent}% for 5 min"
  namespace           = "Collective/${var.environment}"
  metric_name         = "mem_used_percent"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 5
  threshold           = var.memory_alarm_percent
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { InstanceId = aws_instance.this.id }
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  tags                = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "disk_data" {
  for_each            = toset(["/", "/data"])
  alarm_name          = "${local.name}-app-disk-${each.value == "/" ? "root" : trimprefix(each.value, "/")}-high"
  alarm_description   = "disk_used_percent ${each.value} > ${var.disk_alarm_percent}%"
  namespace           = "Collective/${var.environment}"
  metric_name         = "disk_used_percent"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = var.disk_alarm_percent
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { InstanceId = aws_instance.this.id, path = each.value }
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  tags                = local.common_tags
}

# --- DLM: daily EBS snapshots of the data volume -------------------------------------------------
data "aws_iam_policy_document" "dlm_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["dlm.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "dlm" {
  name               = "${local.name}-dlm"
  assume_role_policy = data.aws_iam_policy_document.dlm_trust.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "dlm" {
  role       = aws_iam_role.dlm.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "data_daily" {
  description        = "${local.name}: daily snapshot of the data volume"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]
    target_tags    = { Backup = "${local.name}-daily" }

    schedule {
      name      = "daily"
      copy_tags = true
      tags_to_add = {
        SnapshotCreator = "dlm"
        Environment     = var.environment
      }
      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = [var.snapshot_time_utc] # 19:00 UTC = 02:00 Asia/Bangkok
      }
      retain_rule {
        count = var.snapshot_retention_count
      }
    }
  }
  tags = local.common_tags
}
