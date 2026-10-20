output "instance_id" {
  value = aws_instance.this.id
}

output "instance_arn" {
  value = aws_instance.this.arn
}

output "public_ip" {
  description = "Elastic IP — point DNS A records here"
  value       = aws_eip.this.public_ip
}

output "instance_role_name" {
  value = aws_iam_role.instance.name
}

output "instance_role_arn" {
  value = aws_iam_role.instance.arn
}

output "data_volume_id" {
  value = aws_ebs_volume.data.id
}

output "alerts_topic_arn" {
  value = aws_sns_topic.alerts.arn
}
