output "irsa_role_arns" {
  value = { for k, v in aws_iam_role.irsa : k => v.arn }
}

output "external_secrets_role_arn" {
  value = aws_iam_role.external_secrets.arn
}

output "lb_controller_role_arn" {
  value = aws_iam_role.lb_controller.arn
}

output "cluster_autoscaler_role_arn" {
  value = aws_iam_role.cluster_autoscaler.arn
}

output "github_actions_role_arn" {
  value = aws_iam_role.github_actions.arn
}

output "velero_role_arn" {
  value = aws_iam_role.velero.arn
}

output "xray_role_arn" {
  value = aws_iam_role.xray.arn
}

output "fluent_bit_role_arn" {
  value = aws_iam_role.fluent_bit.arn
}

output "keda_operator_role_arn" {
  value = aws_iam_role.keda_operator.arn
}
