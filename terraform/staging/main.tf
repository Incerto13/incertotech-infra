# incertotech — staging edge (certificate + CloudFront + DNS). The cluster
# itself is in ../shared; staging is the `incertotech-staging` namespace on it.

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
    key     = "staging/terraform.tfstate"
    region  = "us-east-1"
    profile = "incertotech-infra"
  }
}

provider "aws" {
  region  = "us-east-1"
  profile = var.aws_profile

  default_tags {
    tags = {
      Project     = "incertotech"
      ManagedBy   = "terraform"
      Environment = "staging"
    }
  }
}

variable "aws_profile" {
  type    = string
  default = "incertotech-infra"
}

variable "cutover" {
  description = "Point staging DNS at CloudFront (k3s). Set false only together with restoring the compose A records."
  type        = bool
  default     = true
}

data "terraform_remote_state" "shared" {
  backend = "s3"
  config = {
    bucket  = "incertotech-terraform-state"
    key     = "shared/terraform.tfstate"
    region  = "us-east-1"
    profile = var.aws_profile
  }
}

module "edge" {
  source = "../modules/edge"

  env             = "staging"
  origin_dns_name = data.terraform_remote_state.shared.outputs.origin_dns_name
  cutover         = var.cutover

  # No hosted zone of their own: records go into the staging.incertotech.com zone.
  zone_for_host = {
    "node-ecommerce.staging.incertotech.com" = "staging.incertotech.com"
    "django-blog.staging.incertotech.com"    = "staging.incertotech.com"
  }

  # Same seven hostnames nginx/default.conf-staging serves today.
  hosts = [
    "staging.incertotech.com",
    "react-to-do.staging.incertotech.com",
    "react-electoral-map.staging.incertotech.com",
    "react-course-admin.staging.incertotech.com",
    "nest-to-do-api.staging.incertotech.com",
    "nest-blog-api.staging.incertotech.com",
    "nest-course-admin-api.staging.incertotech.com",
    "node-ecommerce.staging.incertotech.com",
    "django-blog.staging.incertotech.com",
  ]
}

output "distribution_domain_name" {
  value = module.edge.distribution_domain_name
}

output "certificate_arn" {
  value = module.edge.certificate_arn
}
