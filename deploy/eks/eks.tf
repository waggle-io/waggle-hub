module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.11"

  cluster_name    = var.cluster_name
  cluster_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Allow public access to the cluster API endpoint
  cluster_endpoint_public_access = true

  # Enable IRSA (OIDC provider)
  enable_irsa = true

  # EKS managed node group
  eks_managed_node_groups = {
    default = {
      name = "${var.cluster_name}-ng"

      instance_types = var.node_instance_types
      disk_size      = var.node_disk_size

      min_size     = var.node_min_size
      max_size     = var.node_max_size
      desired_size = var.node_desired_size

      # Use AL2023 for better security posture
      ami_type = "AL2023_x86_64_STANDARD"

      labels = {
        "node.kubernetes.io/purpose" = "general"
      }

      tags = var.tags
    }
  }

  # Cluster access entry: grant the caller admin rights
  enable_cluster_creator_admin_permissions = true

  tags = var.tags
}
