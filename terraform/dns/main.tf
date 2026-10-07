# incertotech — the incertotech.com hosted zone and the records that belong to
# no environment (mail, leftovers). The per-environment host records (A/AAAA
# for each app, ACM validation CNAMEs) are owned by ../staging and
# ../production through modules/edge, which write into this zone.
#
# The account started with one delegated hosted zone per subdomain; they are
# being folded into this apex zone with bin/dns-fold.sh (one atomic Route53
# batch per sub-zone, then the old zone is deleted 48h later). Progress is in
# fold-log.txt. A folded record is adopted into terraform with an `import`
# block in the stack that owns it.

terraform {
  required_version = ">= 1.8"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket  = "incertotech-terraform-state"
    key     = "dns/terraform.tfstate"
    region  = "us-east-1"
    profile = "incertotech-infra"
  }
}

provider "aws" {
  region  = "us-east-1"
  profile = var.aws_profile

  default_tags {
    tags = {
      Project   = "incertotech"
      ManagedBy = "terraform"
      Root      = "dns"
    }
  }
}

variable "aws_profile" {
  type    = string
  default = "incertotech-infra"
}

# ───────────────────────────── zone ─────────────────────────────

# Created by the Route53 registrar when the domain was registered; the
# registrar's NS records point at this zone's delegation set, so it must never
# be replaced.
import {
  to = aws_route53_zone.apex
  id = "Z2QSMWGZ0A8NUZ"
}

resource "aws_route53_zone" "apex" {
  name    = "incertotech.com"
  comment = "HostedZone created by Route53 Registrar"

  lifecycle {
    prevent_destroy = true
  }
}

# ───────────────────────────── records ─────────────────────────────

locals {
  records = {
    # Amazon SES: DKIM for incertotech.com, custom MAIL FROM on mail.incertotech.com.
    ses_dkim_1 = { name = "cir7gyjlyza4rh5pcvcgbexmkiqwbkas._domainkey", type = "CNAME", ttl = 1800, values = ["cir7gyjlyza4rh5pcvcgbexmkiqwbkas.dkim.amazonses.com"] }
    ses_dkim_2 = { name = "om5b7hg3xa5vu5krpzathro7yhconbko._domainkey", type = "CNAME", ttl = 1800, values = ["om5b7hg3xa5vu5krpzathro7yhconbko.dkim.amazonses.com"] }
    ses_dkim_3 = { name = "tt66yxyl3blr5unmizcro22l3l3z3n7y._domainkey", type = "CNAME", ttl = 1800, values = ["tt66yxyl3blr5unmizcro22l3l3z3n7y.dkim.amazonses.com"] }
    ses_mx     = { name = "mail", type = "MX", ttl = 300, values = ["10 feedback-smtp.us-east-1.amazonses.com"] }
    ses_spf    = { name = "mail", type = "TXT", ttl = 300, values = ["v=spf1 include:amazonses.com ~all"] }

    # Validation CNAMEs for certificates that no longer exist in this account
    # (a Comodo/Sectigo cert, and an ACM cert from before the edge module).
    # Kept as found; safe to delete once confirmed unused.
    legacy_comodo_validation = { name = "_b1bcbd8aee10408fd8ff8dfcffd11136", type = "CNAME", ttl = 300, values = ["15B13A74C4D523244223B53FBFF0A1DC.70C3E23F2F9CE2570B13B3B0AD1EF55E.eb5250d05dd5b8b.comodoca.com"] }
    legacy_acm_validation    = { name = "_cedfa544b6e1a0399479fd1084052a35", type = "CNAME", ttl = 300, values = ["_58ad25486d610be815afc8f382de9870.xyscsmcmgv.acm-validations.aws."] }

    # Retired apps (no longer served by compose or k8s); folded in from their
    # own zones on 2026-10-07 unchanged, still pointing at the compose prod box.
    # Safe to delete.
    legacy_django_tictactoe = { name = "django-tictactoe", type = "A", ttl = 300, values = ["54.210.33.130"] }
    legacy_django_ecommerce = { name = "django-ecommerce", type = "A", ttl = 300, values = ["54.210.33.130"] }
  }
}

import {
  for_each = local.records
  to       = aws_route53_record.this[each.key]
  id       = "${aws_route53_zone.apex.zone_id}_${each.value.name}.incertotech.com_${each.value.type}"
}

resource "aws_route53_record" "this" {
  for_each = local.records

  zone_id = aws_route53_zone.apex.zone_id
  name    = "${each.value.name}.incertotech.com"
  type    = each.value.type
  ttl     = each.value.ttl
  records = each.value.values
}

output "zone_id" {
  value = aws_route53_zone.apex.zone_id
}

output "name_servers" {
  value = aws_route53_zone.apex.name_servers
}
