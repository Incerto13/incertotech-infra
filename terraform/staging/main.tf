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
  description = "Set true (in terraform.tfvars or -var) to repoint staging DNS at CloudFront."
  type        = bool
  default     = false
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

  # Same seven hostnames nginx/default.conf-staging serves today.
  hosts = [
    "staging.incertotech.com",
    "react-to-do.staging.incertotech.com",
    "react-electoral-map.staging.incertotech.com",
    "react-course-admin.staging.incertotech.com",
    "nest-to-do-api.staging.incertotech.com",
    "nest-blog-api.staging.incertotech.com",
    "nest-course-admin-api.staging.incertotech.com",
  ]
}

output "distribution_domain_name" {
  value = module.edge.distribution_domain_name
}

output "certificate_arn" {
  value = module.edge.certificate_arn
}
