locals {
  oidc_host = replace(var.oidc_provider_url, "https://", "")
}

# ---------------------------------------------------------------------------
# Helper: IRSA trust policy factory
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "irsa_trust" {
  for_each = var.service_accounts

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = ["system:serviceaccount:${each.value.namespace}:${each.value.sa_name}"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "irsa" {
  for_each           = var.service_accounts
  name               = "cloudmart-${each.key}-role-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.irsa_trust[each.key].json
  tags               = { Service = each.key, Environment = var.environment }
}

# ---------------------------------------------------------------------------
# product-service → DynamoDB (table-scoped)
# ---------------------------------------------------------------------------
resource "aws_iam_role_policy" "product_dynamodb" {
  name = "product-service-dynamodb"
  role = aws_iam_role.irsa["product-service"].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DynamoDBTableAccess"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:DeleteItem",
          "dynamodb:Scan",
          "dynamodb:Query",
          "dynamodb:BatchGetItem",
          "dynamodb:BatchWriteItem",
        ]
        Resource = [
          var.dynamodb_table_arn,
          "${var.dynamodb_table_arn}/index/*",
        ]
      },
      {
        Sid      = "KMSDecrypt"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = [var.app_kms_key_arn]
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# order-service → SQS SendMessage
# ---------------------------------------------------------------------------
resource "aws_iam_role_policy" "order_sqs" {
  name = "order-service-sqs"
  role = aws_iam_role.irsa["order-service"].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "SQSSend"
        Effect   = "Allow"
        Action   = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"]
        Resource = [var.sqs_queue_arn]
      },
      {
        Sid      = "KMSDecrypt"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = [var.app_kms_key_arn]
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# notification-service → SQS receive/delete + SES send
# ---------------------------------------------------------------------------
resource "aws_iam_role_policy" "notification_sqs_ses" {
  name = "notification-service-sqs-ses"
  role = aws_iam_role.irsa["notification-service"].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SQSConsume"
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:ChangeMessageVisibility",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl",
        ]
        Resource = [var.sqs_queue_arn]
      },
      {
        Sid      = "SESSend"
        Effect   = "Allow"
        Action   = ["ses:SendEmail", "ses:SendRawEmail"]
        Resource = ["*"]
        Condition = {
          StringEquals = {
            "ses:FromAddress" = var.ses_from_email
          }
        }
      },
      {
        Sid      = "KMSDecrypt"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = [var.app_kms_key_arn]
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# user-service → Secrets Manager (read DB credentials only)
# ---------------------------------------------------------------------------
resource "aws_iam_role_policy" "user_secrets" {
  name = "user-service-secrets"
  role = aws_iam_role.irsa["user-service"].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "SecretsManagerRead"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        Resource = [var.rds_secret_arn]
      },
      {
        Sid      = "KMSDecrypt"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = [var.app_kms_key_arn]
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# External Secrets Operator → read all cloudmart secrets
# ---------------------------------------------------------------------------
resource "aws_iam_role" "external_secrets" {
  name = "cloudmart-external-secrets-role-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRoleWithWebIdentity"
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Condition = {
        StringEquals = {
          "${local.oidc_host}:sub" = "system:serviceaccount:external-secrets:external-secrets-sa"
          "${local.oidc_host}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "external_secrets" {
  name = "external-secrets-sm-read"
  role = aws_iam_role.external_secrets.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
          "secretsmanager:ListSecrets",
        ]
        Resource = ["arn:aws:secretsmanager:${var.aws_region}:${var.account_id}:secret:cloudmart/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = compact([var.app_kms_key_arn, var.rds_kms_key_arn])
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# AWS Load Balancer Controller role
# ---------------------------------------------------------------------------
resource "aws_iam_role" "lb_controller" {
  name = "cloudmart-lb-controller-role-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRoleWithWebIdentity"
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Condition = {
        StringEquals = {
          "${local.oidc_host}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
          "${local.oidc_host}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_policy" "lb_controller" {
  name   = "cloudmart-lb-controller-policy-${var.environment}"
  policy = file("${path.module}/lb-controller-policy.json")
}

resource "aws_iam_role_policy_attachment" "lb_controller" {
  role       = aws_iam_role.lb_controller.name
  policy_arn = aws_iam_policy.lb_controller.arn
}

# ---------------------------------------------------------------------------
# Cluster Autoscaler role
# ---------------------------------------------------------------------------
resource "aws_iam_role" "cluster_autoscaler" {
  name = "cloudmart-cluster-autoscaler-role-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRoleWithWebIdentity"
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Condition = {
        StringEquals = {
          "${local.oidc_host}:sub" = "system:serviceaccount:kube-system:cluster-autoscaler"
          "${local.oidc_host}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "cluster_autoscaler" {
  name = "cluster-autoscaler"
  role = aws_iam_role.cluster_autoscaler.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances",
          "autoscaling:DescribeLaunchConfigurations",
          "autoscaling:DescribeScalingActivities",
          "autoscaling:DescribeTags",
          "autoscaling:SetDesiredCapacity",
          "autoscaling:TerminateInstanceInAutoScalingGroup",
          "ec2:DescribeImages",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplateVersions",
          "ec2:GetInstanceTypesFromInstanceRequirements",
          "eks:DescribeNodegroup",
        ]
        Resource = ["*"]
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# GitHub Actions OIDC role (for CI/CD)
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "github_oidc_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = ["arn:aws:iam::${var.account_id}:oidc-provider/token.actions.githubusercontent.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_org}/${var.github_repo}:*"]
    }
  }
}

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_role" "github_actions" {
  name               = "cloudmart-github-actions-role-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.github_oidc_trust.json
}

resource "aws_iam_role_policy" "github_actions" {
  name = "github-actions-ci-cd"
  role = aws_iam_role.github_actions.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ECRAuth"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = ["*"]
      },
      {
        Sid    = "ECRPush"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
        ]
        Resource = ["arn:aws:ecr:${var.aws_region}:${var.account_id}:repository/cloudmart/*"]
      },
      {
        Sid    = "EKSAccess"
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster",
          "eks:ListClusters",
        ]
        Resource = ["*"]
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# Velero backup role (IRSA)
# ---------------------------------------------------------------------------
resource "aws_iam_role" "velero" {
  name = "cloudmart-velero-role-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRoleWithWebIdentity"
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Condition = {
        StringEquals = {
          "${local.oidc_host}:sub" = "system:serviceaccount:velero:velero-server"
          "${local.oidc_host}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "velero" {
  name = "velero-s3-ec2"
  role = aws_iam_role.velero.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3BucketAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject", "s3:PutObject", "s3:DeleteObject",
          "s3:ListBucket", "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts",
        ]
        Resource = [
          "arn:aws:s3:::cloudmart-velero-${var.account_id}",
          "arn:aws:s3:::cloudmart-velero-${var.account_id}/*",
        ]
      },
      {
        Sid    = "EC2Snapshots"
        Effect = "Allow"
        Action = [
          "ec2:CreateSnapshot", "ec2:DeleteSnapshot",
          "ec2:DescribeSnapshots", "ec2:DescribeVolumes",
          "ec2:CreateTags",
        ]
        Resource = ["*"]
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# X-Ray daemon role (IRSA)
# ---------------------------------------------------------------------------
resource "aws_iam_role" "xray" {
  name = "cloudmart-xray-role-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRoleWithWebIdentity"
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Condition = {
        StringEquals = {
          "${local.oidc_host}:sub" = "system:serviceaccount:kube-system:xray-daemon"
          "${local.oidc_host}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "xray" {
  role       = aws_iam_role.xray.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

# ---------------------------------------------------------------------------
# aws-for-fluent-bit log shipping role (IRSA)
# ---------------------------------------------------------------------------
resource "aws_iam_role" "fluent_bit" {
  name = "cloudmart-fluent-bit-role-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRoleWithWebIdentity"
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Condition = {
        StringEquals = {
          "${local.oidc_host}:sub" = "system:serviceaccount:kube-system:aws-for-fluent-bit"
          "${local.oidc_host}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "fluent_bit" {
  role       = aws_iam_role.fluent_bit.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# ---------------------------------------------------------------------------
# KEDA operator role (IRSA) — queries SQS queue depth for autoscaling
# ---------------------------------------------------------------------------
resource "aws_iam_role" "keda_operator" {
  name = "cloudmart-keda-operator-role-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRoleWithWebIdentity"
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Condition = {
        StringEquals = {
          "${local.oidc_host}:sub" = "system:serviceaccount:keda:keda-operator"
          "${local.oidc_host}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "keda_operator" {
  name = "keda-sqs-read"
  role = aws_iam_role.keda_operator.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sqs:GetQueueAttributes", "sqs:GetQueueUrl"]
      Resource = [var.sqs_queue_arn]
    }]
  })
}
