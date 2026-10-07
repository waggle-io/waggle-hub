variable "organization_name" {
  description = "Name of the organization"
  type        = string
  default     = "RedHat"
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "edge-fleet-mgmt"
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "ap-south-1"
}

variable "kubernetes_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.34"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "List of availability zones. Defaults to first 3 AZs in the region."
  type        = list(string)
  default     = []
}

variable "node_instance_types" {
  description = "EC2 instance types for the managed node group"
  type        = list(string)
  default     = ["t2.xlarge"]
}

variable "node_desired_size" {
  description = "Desired number of nodes in the managed node group"
  type        = number
  default     = 1
}

variable "node_min_size" {
  description = "Minimum number of nodes in the managed node group"
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Maximum number of nodes in the managed node group"
  type        = number
  default     = 2
}

variable "node_disk_size" {
  description = "Disk size (GiB) for each node"
  type        = number
  default     = 50
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "domain_name" {
  description = "Base domain name managed in Route53 (e.g., example.com). A wildcard cert *.domain_name will be issued."
  type        = string
  default     = "edgedemos.io"
}

variable "services" {
  description = "Services to expose externally via the shared ALB. Each entry creates a target group, HTTPS listener rule, and Route53 A record."
  type = list(object({
    name              = string                # Used to name the target group and listener rule
    port              = number                # Backend port the target group routes to
    host              = string                # Full hostname (e.g., api.example.com)
    health_check_path = optional(string, "/") # ALB health check path
  }))
  default = [
     { name = "flightctl-api", port = 3443, host = "api.flightctl.edgedemos.io" },
     { name = "flightctl-ui",  port = 8080, host = "ui.flightctl.edgedemos.io" },
     { name = "zipkin",        port = 9411, host = "zipkin.flightctl.edgedemos.io" },
     { name = "sso",           port = 9411, host = "sso.flightctl.edgedemos.io" },
   ]
}
