# S3 buckets and IRSA roles for Loki, Tempo and Mimir.

locals {
  lgtm_namespace = "lgtm"
  s3_components = {
    loki  = { service_account = "loki" }
    tempo = { service_account = "tempo" }
    mimir = { service_account = "mimir" }
  }
}

resource "aws_s3_bucket" "lgtm" {
  #checkov:skip=CKV2_AWS_61:False positive, lifecycle configuration exists via for_each
  #checkov:skip=CKV2_AWS_6:False positive, public access block exists via for_each
  #checkov:skip=CKV_AWS_18:Access logging not needed for a demo
  #checkov:skip=CKV_AWS_144:Cross-region replication not needed for a demo
  #checkov:skip=CKV_AWS_145:SSE-S3 (AES256) is used for the demo; KMS adds cost and no value here
  #checkov:skip=CKV2_AWS_62:Event notifications not needed
  #checkov:skip=CKV_AWS_21:Versioning would defeat 7-day expiry and force_destroy cleanup for a demo
  for_each      = local.s3_components
  bucket        = "${local.name}-${each.key}-${local.account_id}-${var.region}"
  force_destroy = true
  tags          = merge(local.tags, { Component = each.key })

  depends_on = [terraform_data.account_guard]
}

resource "aws_s3_bucket_server_side_encryption_configuration" "lgtm" {
  for_each = aws_s3_bucket.lgtm
  bucket   = each.value.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "lgtm" {
  for_each                = aws_s3_bucket.lgtm
  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "lgtm" {
  for_each = aws_s3_bucket.lgtm
  bucket   = each.value.id

  rule {
    id     = "expire-after-retention"
    status = "Enabled"
    filter {}
    expiration {
      days = var.retention_days
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

data "aws_iam_policy_document" "s3_assume" {
  for_each = local.s3_components
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:${local.lgtm_namespace}:${each.value.service_account}"]
    }
    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "s3_access" {
  for_each = local.s3_components
  statement {
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.lgtm[each.key].arn]
  }
  statement {
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]
    resources = ["${aws_s3_bucket.lgtm[each.key].arn}/*"]
  }
}

resource "aws_iam_role" "s3" {
  for_each           = local.s3_components
  name               = "${local.name}-${each.key}-s3"
  assume_role_policy = data.aws_iam_policy_document.s3_assume[each.key].json
  tags               = local.tags
}

resource "aws_iam_role_policy" "s3" {
  for_each = local.s3_components
  name     = "s3-access"
  role     = aws_iam_role.s3[each.key].id
  policy   = data.aws_iam_policy_document.s3_access[each.key].json
}
