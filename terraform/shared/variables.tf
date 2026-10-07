variable "aws_profile" {
  description = "AWS CLI profile for account 249107242695 (see K8S_CONTEXT.md §5)."
  type        = string
  default     = "incertotech-infra"
}

variable "instance_type" {
  description = "k3s node. Sized from measured usage: both envs' containers < 800 MB + k3s ~600 MB fits 2 GB. Deliberately small."
  type        = string
  default     = "t3.small"
}

variable "root_volume_gb" {
  description = "Root disk. ~10 app images per env plus k3s; 8 GB default is too tight."
  type        = number
  default     = 20
}

variable "github_repo" {
  description = "GitHub repo (owner/name) whose Actions may assume the deploy role."
  type        = string
  default     = "Incerto13/incertotech-infra"
}
