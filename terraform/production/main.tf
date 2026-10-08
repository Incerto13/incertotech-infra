# incertotech — production edge (certificate + CloudFront + DNS). The cluster
# itself is in ../shared; production is the `incertotech-prod` namespace on it.

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
    key     = "production/terraform.tfstate"
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
      Environment = "production"
    }
  }
}

variable "aws_profile" {
  type    = string
  default = "incertotech-infra"
}

variable "cutover" {
  description = "Point production DNS at CloudFront (k3s). false = back to the docker-compose instance (legacy_ipv4)."
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

data "terraform_remote_state" "dns" {
  backend = "s3"
  config = {
    bucket  = "incertotech-terraform-state"
    key     = "dns/terraform.tfstate"
    region  = "us-east-1"
    profile = var.aws_profile
  }
}

locals {
  # The seven hostnames nginx/default.conf-prod serves today, plus the two
  # k8s-only apps.
  hosts = [
    "incertotech.com",
    "react-to-do.incertotech.com",
    "react-electoral-map.incertotech.com",
    "react-course-admin.incertotech.com",
    "nest-to-do-api.incertotech.com",
    "nest-blog-api.incertotech.com",
    "nest-course-admin-api.incertotech.com",
    "node-ecommerce.incertotech.com",
    "django-blog.incertotech.com",
  ]
}

module "edge" {
  source = "../modules/edge"

  env             = "production"
  origin_dns_name = data.terraform_remote_state.shared.outputs.origin_dns_name
  zone_id         = data.terraform_remote_state.dns.outputs.zone_id
  cutover         = var.cutover
  legacy_ipv4     = "54.210.33.130" # the docker-compose prod instance (rollback target)

  hosts = local.hosts
}

output "distribution_domain_name" {
  value = module.edge.distribution_domain_name
}

output "certificate_arn" {
  value = module.edge.certificate_arn
}
