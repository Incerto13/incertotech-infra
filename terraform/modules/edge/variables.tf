variable "env" {
  description = "staging | production — used in names/tags only."
  type        = string
}

variable "hosts" {
  description = "All public hostnames for this environment. The first is the certificate's primary name."
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

variable "zone_id" {
  description = "Route53 zone every record is written into (the incertotech.com apex, from ../../dns)."
  type        = string
}

variable "cutover" {
  description = "false: hosts point at legacy_ipv4 (the docker-compose instance). true: hosts point at CloudFront."
  type        = bool
  default     = false
}

variable "legacy_ipv4" {
  description = "The docker-compose instance's public IP, used while cutover = false. null: no A records before cutover."
  type        = string
  default     = null
}
