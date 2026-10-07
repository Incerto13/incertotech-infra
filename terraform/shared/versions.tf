terraform {
  required_version = ">= 1.8"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Remote state (unlike techneip's local tfstate files). Bucket created once by
  # hand on 2026-10-04: versioned, private, SSE-S3. No DynamoDB lock table —
  # single operator; add one if a second person ever runs terraform here.
  backend "s3" {
    bucket  = "incertotech-terraform-state"
    key     = "shared/terraform.tfstate"
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
      Root      = "shared"
    }
  }
}
