# edge — one environment's public entry point: ACM certificate + CloudFront
# distribution + Route53 alias records. Used by ../../staging and ../../production.
#
# This is the whole "never expires" design. ACM issues and renews the
# certificate; CloudFront serves it and redirects 80 -> 443; nothing inside the
# cluster holds a certificate. CloudFront reaches the k3s node over plain HTTP
# (the node's security group admits CloudFront's ranges only) and forwards the
# viewer's Host header so Traefik can route by hostname.
#
# DNS: every incertotech hostname has its OWN hosted zone (the account was set
# up that way; the user chose to keep it). So each ACM validation CNAME and each
# alias record is written into the zone named exactly after that host.
# Alias records are gated by var.cutover — until it is true the existing A
# records keep pointing at the docker-compose instances and nothing changes
# for visitors.

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

locals {
  apex = var.hosts[0]
}

data "aws_route53_zone" "host" {
  for_each = toset(var.hosts)
  name     = "${each.value}."
}

# ───────────────────────────── certificate ─────────────────────────────
# ACM for CloudFront must live in us-east-1, which is also our only region.

resource "aws_acm_certificate" "this" {
  domain_name               = local.apex
  subject_alternative_names = slice(var.hosts, 1, length(var.hosts))
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = "incertotech-${var.env}" }
}

resource "aws_route53_record" "validation" {
  for_each = {
    for dvo in aws_acm_certificate.this.domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id         = data.aws_route53_zone.host[each.key].zone_id
  name            = each.value.name
  type            = each.value.type
  ttl             = 300
  records         = [each.value.record]
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "this" {
  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [for r in aws_route53_record.validation : r.fqdn]
}

# ───────────────────────────── CloudFront ─────────────────────────────

# AWS-managed policies: no caching at all (these are dynamic demo apps), and
# forward every viewer header/cookie/query string — including Host — to origin.
data "aws_cloudfront_cache_policy" "caching_disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "all_viewer" {
  name = "Managed-AllViewer"
}

resource "aws_cloudfront_distribution" "this" {
  enabled         = true
  comment         = "incertotech ${var.env}"
  aliases         = var.hosts
  price_class     = "PriceClass_100" # US/Canada/Europe edges — cheapest
  http_version    = "http2and3"
  is_ipv6_enabled = true

  origin {
    origin_id   = "k3s"
    domain_name = var.origin_dns_name

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id         = "k3s"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    compress                 = true
    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.this.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = { Name = "incertotech-${var.env}" }
}

# ───────────────────────────── DNS cutover ─────────────────────────────

resource "aws_route53_record" "alias" {
  for_each = var.cutover ? toset(var.hosts) : toset([])

  zone_id = data.aws_route53_zone.host[each.value].zone_id
  name    = each.value
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.this.domain_name
    zone_id                = aws_cloudfront_distribution.this.hosted_zone_id
    evaluate_target_health = false
  }

  # Each zone already holds an A record for its own name pointing at the
  # compose instance; cutover replaces it in place.
  allow_overwrite = true
}

resource "aws_route53_record" "alias_ipv6" {
  for_each = var.cutover ? toset(var.hosts) : toset([])

  zone_id = data.aws_route53_zone.host[each.value].zone_id
  name    = each.value
  type    = "AAAA"

  alias {
    name                   = aws_cloudfront_distribution.this.domain_name
    zone_id                = aws_cloudfront_distribution.this.hosted_zone_id
    evaluate_target_health = false
  }

  allow_overwrite = true
}
