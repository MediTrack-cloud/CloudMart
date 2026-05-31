output "cluster_name" { value = aws_eks_cluster.main.name }
output "cluster_endpoint" { value = aws_eks_cluster.main.endpoint }
output "cluster_ca" { value = aws_eks_cluster.main.certificate_authority[0].data }
output "oidc_provider_arn" { value = aws_iam_openid_connect_provider.eks.arn }
output "oidc_provider_url" { value = aws_iam_openid_connect_provider.eks.url }
output "node_role_arn" { value = aws_iam_role.node.arn }
output "node_role_name" { value = aws_iam_role.node.name }
output "cluster_security_group_id" { value = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id }
