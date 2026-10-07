variable "env" {
  description = "staging | production — used in names/tags only."
  type        = string
}

variable "hosts" {
  description = "All public hostnames for this environment. The first is the certificate's primary name. Each must have its own Route53 hosted zone."
  type        = list(string)

  validation {
    condition     = length(var.hosts) >= 1
    error_message = "hosts must contain at least one hostname."
  }
}

variable "origin_dns_name" {
  description = "DNS name CloudFront fetches from over HTTP (the k3s node's EIP public DNS, from the shared root)."
  type        = string
}

variable "cutover" {
  description = "false: build cert + CloudFront only, leave the live A records alone. true: repoint every hostname at CloudFront."
  type        = bool
  default     = false
}
