output "certificate_arn" {
  value = aws_acm_certificate_validation.this.certificate_arn
}

output "distribution_id" {
  value = aws_cloudfront_distribution.this.id
}

output "distribution_domain_name" {
  description = "Test the environment before cutover with: curl -H 'Host: <hostname>' https://<this>/"
  value       = aws_cloudfront_distribution.this.domain_name
}
