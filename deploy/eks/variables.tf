variable "organization_name" {
  description = "Name of the organization"
  type        = string
  default     = "kloudstak"
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "waggle-hub"
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
  default     = "waggle.io"
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
    { name = "gitops", port = 3443, host = "gitops.waggle.io" },
  ]
}

variable "secrets_prefix" {
  description = "Path prefix for the hub's Secrets Manager secrets. External Secrets can read every secret under it and nothing else."
  type        = string
  default     = "waggle"
}

variable "secrets" {
  description = "Secrets Manager secrets to create under secrets_prefix, as name => description. Terraform creates them empty; set values with `aws secretsmanager put-secret-value`."
  type        = map(string)
  default = {
    "aws/target-account" = "AWS credentials for the spoke target account, JSON keys: aws_access_key_id, aws_secret_access_key"
    "redhat/pull-secret" = "Red Hat pull secret JSON from console.redhat.com"
    "ssh/hive"           = "SSH key pair Hive uses to gather install logs, JSON keys: ssh-privatekey, ssh-publickey"
  }
}

variable "secrets_recovery_window_in_days" {
  description = "Days a deleted secret can be restored before Secrets Manager removes it permanently (0 deletes immediately)"
  type        = number
  default     = 7
}
