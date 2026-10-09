# ──────────────────────────────────────────────────────────
# AWS Secrets Manager + IRSA for External Secrets Operator
# ──────────────────────────────────────────────────────────
#
# Terraform creates the secret *containers* only. Values are written out of
# band so they never land in Terraform state:
#   aws secretsmanager put-secret-value --secret-id waggle/redhat/pull-secret \
#     --secret-string file://pull-secret.json
#
# External Secrets reads them through a ClusterSecretStore
# (apps/externalsecrets/clustersecretstore.yaml) using the IRSA role below.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  # Every secret External Secrets may read lives under this prefix; the IRSA
  # policy is scoped to it, so new secrets need no IAM change.
  secrets_arn_pattern = "arn:${data.aws_partition.current.partition}:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:${var.secrets_prefix}/*"
}

resource "aws_secretsmanager_secret" "this" {
  for_each = var.secrets

  name                    = "${var.secrets_prefix}/${each.key}"
  description             = each.value
  recovery_window_in_days = var.secrets_recovery_window_in_days

  tags = var.tags
}

module "external_secrets_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.39"

  role_name                      = "${var.cluster_name}-external-secrets"
  attach_external_secrets_policy = true

  external_secrets_secrets_manager_arns = [local.secrets_arn_pattern]
  # Secrets use the AWS managed key (aws/secretsmanager), which Secrets Manager
  # decrypts on the caller's behalf; no SSM Parameter Store access either.
  external_secrets_kms_key_arns       = []
  external_secrets_ssm_parameter_arns = []

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["external-secrets:external-secrets"]
    }
  }

  tags = var.tags
}
