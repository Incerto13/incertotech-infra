# incertotech — shared infrastructure (one of each, used by both staging and
# production, which are namespaces on the same cluster).
#
#   • one t3.small running k3s, in the default VPC, with an Elastic IP
#   • security group: :80 from CloudFront's origin-facing ranges ONLY — no SSH;
#     shell access is `aws ssm start-session` (SSM agent ships with AL2023)
#   • an S3 bucket the deploy workflow drops rendered manifests into
#   • a GitHub OIDC provider + role so Actions needs no AWS keys: it uploads the
#     manifest to S3 and runs `incertotech-deploy` on the box through SSM
#
# What is NOT here, on purpose: no ALB/NLB (CloudFront terminates TLS, see
# ../modules/edge), no cert-manager, no RDS, no EKS. See K8S_CONTEXT.md §2.

data "aws_caller_identity" "current" {}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default_a" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "availability-zone"
    values = ["us-east-1a"]
  }
}

# Latest Amazon Linux 2023 (x86_64). The instance ignores later changes to this
# value so a new AMI release never silently replaces the box.
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# CloudFront's origin-facing IP ranges, maintained by AWS.
data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

# ───────────────────────────── network ─────────────────────────────

resource "aws_security_group" "k3s" {
  name        = "incertotech-k3s"
  description = "k3s node: HTTP from CloudFront only; no SSH (use SSM)"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "HTTP from CloudFront origin-facing ranges"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "incertotech-k3s" }
}

resource "aws_eip" "k3s" {
  domain = "vpc"
  tags   = { Name = "incertotech-k3s" }
}

resource "aws_eip_association" "k3s" {
  instance_id   = aws_instance.k3s.id
  allocation_id = aws_eip.k3s.id
}

# ───────────────────────────── deploy artifacts ─────────────────────────────

resource "aws_s3_bucket" "artifacts" {
  bucket = "incertotech-deploy-artifacts-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Rendered manifests contain decrypted Secrets: the deploy workflow deletes each
# one after applying it; this expires any leftover/noncurrent versions too.
resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    id     = "expire-deploy-manifests"
    status = "Enabled"
    filter {}
    expiration {
      days = 1
    }
    noncurrent_version_expiration {
      noncurrent_days = 1
    }
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ───────────────────────────── instance role ─────────────────────────────

data "aws_iam_policy_document" "instance_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = "incertotech-k3s-instance"
  assume_role_policy = data.aws_iam_policy_document.instance_assume.json
}

# SSM agent registration + Session Manager + Run Command.
resource "aws_iam_role_policy_attachment" "instance_ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "instance_artifacts" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.artifacts.arn}/*"]
  }
  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.artifacts.arn]
  }
}

resource "aws_iam_role_policy" "instance_artifacts" {
  name   = "read-deploy-artifacts"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.instance_artifacts.json
}

resource "aws_iam_instance_profile" "instance" {
  name = "incertotech-k3s-instance"
  role = aws_iam_role.instance.name
}

# ───────────────────────────── the node ─────────────────────────────

resource "aws_instance" "k3s" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnets.default_a.ids[0]
  vpc_security_group_ids = [aws_security_group.k3s.id]
  iam_instance_profile   = aws_iam_instance_profile.instance.name
  user_data              = file("${path.module}/user-data.sh")

  root_block_device {
    volume_size = var.root_volume_gb
    volume_type = "gp3"
    encrypted   = true
  }

  metadata_options {
    http_tokens = "required" # IMDSv2 only
  }

  lifecycle {
    # A new AL2023 AMI or an edited bootstrap script must not recreate the
    # node (and lose the Postgres volumes). Rebuild deliberately with
    # `terraform taint` / `-replace` if ever needed.
    ignore_changes = [ami, user_data]
  }

  tags = { Name = "incertotech-k3s" }
}

# ───────────────────────────── GitHub Actions (OIDC) ─────────────────────────────
# Same idea as techneip's github_actions_role: no long-lived AWS keys in GitHub.

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # AWS validates GitHub's OIDC provider through its own trust store; the
  # thumbprint is required by the API but not used for this issuer.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_policy_document" "github_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:*"]
    }
  }
}

resource "aws_iam_role" "github_deploy" {
  name               = "incertotech-github-deploy"
  assume_role_policy = data.aws_iam_policy_document.github_assume.json
}

data "aws_iam_policy_document" "github_deploy" {
  # upload the rendered manifest, and delete it after the apply (it contains
  # the decrypted Kubernetes Secrets)
  statement {
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.artifacts.arn}/*"]
  }
  # run `incertotech-deploy` on the node and read the result
  statement {
    actions = ["ssm:SendCommand"]
    resources = [
      aws_instance.k3s.arn,
      "arn:aws:ssm:us-east-1::document/AWS-RunShellScript",
    ]
  }
  statement {
    actions   = ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations"]
    resources = ["*"]
  }
  statement {
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "github_deploy" {
  name   = "deploy-to-k3s"
  role   = aws_iam_role.github_deploy.id
  policy = data.aws_iam_policy_document.github_deploy.json
}
