output "instance_id" {
  value = aws_instance.k3s.id
}

output "public_ip" {
  value = aws_eip.k3s.public_ip
}

# CloudFront needs a DNS name for a custom origin, not an IP. The EIP's public
# DNS name is stable for as long as the EIP is attached.
output "origin_dns_name" {
  value = aws_eip.k3s.public_dns
}

output "security_group_id" {
  value = aws_security_group.k3s.id
}

output "artifacts_bucket" {
  value = aws_s3_bucket.artifacts.bucket
}

output "github_deploy_role_arn" {
  description = "Assumed by .github/workflows/k8s-deploy.yml via GitHub OIDC (ARN is hardcoded there)."
  value       = aws_iam_role.github_deploy.arn
}
