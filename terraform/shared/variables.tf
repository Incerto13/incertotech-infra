variable "aws_profile" {
  description = "AWS CLI profile for account 249107242695 (see K8S_CONTEXT.md §5)."
  type        = string
  default     = "incertotech-infra"
}

variable "instance_type" {
  # Was t3.small (2 GB), sized from compose measurements. It ran staging alone,
  # but the first prod deploy (2026-10-07) ran it out of memory: both envs are
  # 14 app pods (several with sidecars) + 10 databases + k3s + Traefik.
  description = "k3s node running staging + prod. 4 GB; changing it is an in-place stop/start (EIP and EBS kept)."
  type        = string
  default     = "t3.medium"
}

variable "root_volume_gb" {
  description = "Root disk. ~10 app images per env plus k3s; 8 GB default is too tight."
  type        = number
  default     = 20
}

variable "github_repo" {
  # The repo uses GitHub's immutable OIDC subject (owner@id/name@id), so the
  # token's sub is "repo:Incerto13@41068072/incertotech-infra@826612883:...".
  # Check with: gh api repos/<owner>/<repo>/actions/oidc/customization/sub
  description = "GitHub repo, in the OIDC sub claim's form, whose Actions may assume the deploy role."
  type        = string
  default     = "Incerto13@41068072/incertotech-infra@826612883"
}
