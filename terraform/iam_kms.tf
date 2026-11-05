################################################################################
# KMS — customer-managed key used by notifications' init container (trap 2)
################################################################################

resource "aws_kms_key" "app" {
  description             = "Northwind Retail Group staging application config key"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_kms_alias" "app" {
  name          = "alias/nrg-stag-app"
  target_key_id = aws_kms_key.app.key_id
}

# Encrypted notifications config. scripts/deploy.sh writes this into the
# notifications/notifications-config ConfigMap as config.enc.
# NOTE: aws_kms_ciphertext keeps the plaintext in state. It's fake config, so that's fine here.
resource "aws_kms_ciphertext" "notifications_config" {
  key_id = aws_kms_key.app.key_id

  plaintext = jsonencode({
    service = "notifications"
    sms_provider = {
      name    = "twilio"
      api_key = "SKfake-staging-0000000000000000"
    }
    email_provider = {
      name = "ses"
      from = "no-reply@staging.nrg.example"
    }
    webhook_signing_secret = "whsec_staging_not_a_real_secret"
  })
}

################################################################################
# Node IAM role — nrg-stag-app-node-role
# Standard worker/CNI/ECR policies PLUS an inline kms:Decrypt. This is the
# "we never got around to IRSA" smell that trap 2 hinges on.
################################################################################

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "kms_decrypt" {
  statement {
    sid       = "DecryptAppConfig"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.app.arn] # the key behind alias/nrg-stag-app
  }
}

locals {
  node_managed_policies = {
    worker = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
    cni    = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
    ecr    = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
    ssm    = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }
}

resource "aws_iam_role" "node" {
  name               = "nrg-stag-app-node-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each   = local.node_managed_policies
  role       = aws_iam_role.node.name
  policy_arn = each.value
}

resource "aws_iam_role_policy" "node_kms" {
  name   = "app-config-kms-decrypt"
  role   = aws_iam_role.node.id
  policy = data.aws_iam_policy_document.kms_decrypt.json
}

# Explicit instance profile for the node role. Self-managed groups need an explicit
# profile; this one has a clean name so the trap 2 fix is easy to hand
# out: point the CAST AI node configuration's instanceProfileArn at it.
resource "aws_iam_instance_profile" "node" {
  name = "nrg-stag-app-node-profile"
  role = aws_iam_role.node.name
}

################################################################################
# Trap 2 optional extra layer — a profile whose role is NOT in access entries/aws-auth
################################################################################

resource "aws_iam_role" "decoy" {
  count              = var.enable_trap2_unmapped_decoy ? 1 : 0
  name               = "nrg-stag-app-node-role-v2"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "decoy" {
  for_each   = var.enable_trap2_unmapped_decoy ? local.node_managed_policies : {}
  role       = aws_iam_role.decoy[0].name
  policy_arn = each.value
}

resource "aws_iam_role_policy" "decoy_kms" {
  count  = var.enable_trap2_unmapped_decoy ? 1 : 0
  name   = "app-config-kms-decrypt"
  role   = aws_iam_role.decoy[0].id
  policy = data.aws_iam_policy_document.kms_decrypt.json
}

resource "aws_iam_instance_profile" "decoy" {
  count = var.enable_trap2_unmapped_decoy ? 1 : 0
  name  = "nrg-stag-app-node-profile-v2"
  role  = aws_iam_role.decoy[0].name
}
