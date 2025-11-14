# ==========================================
# EKS Cluster
# ==========================================

locals {
  cluster_name = "team02-eks-cluster"
}

# Create EKS Cluster
resource "aws_eks_cluster" "team02_eks" {
  name     = local.cluster_name
  version  = "1.33"
  role_arn = aws_iam_role.eks_cluster_role.arn

  vpc_config {
    subnet_ids = [
      aws_subnet.team02_private_subnet_a.id,
      aws_subnet.team02_private_subnet_b.id
    ]
    security_group_ids      = [aws_security_group.eks_node_group.id]
    endpoint_public_access  = true
    endpoint_private_access = true
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  tags = {
    Name = local.cluster_name
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
    aws_iam_role_policy_attachment.eks_vpc_resource_controller
  ]
}

# ==========================================
# EKS Node Group
# ==========================================

# Create EKS Node Group
resource "aws_eks_node_group" "team02_node_group" {
  cluster_name    = aws_eks_cluster.team02_eks.name
  node_group_name = "team02-node-group"
  node_role_arn   = aws_iam_role.eks_node_group_role.arn
  subnet_ids = [
    aws_subnet.team02_private_subnet_a.id,
    aws_subnet.team02_private_subnet_b.id
  ]

  scaling_config {
    desired_size = 4
    max_size     = 6
    min_size     = 4
  }

  instance_types = ["t3.medium"]
  capacity_type  = "ON_DEMAND"

  update_config {
    max_unavailable = 1
  }

  tags = {
    Name = "team02-node-group"
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_container_registry_policy,
    aws_eks_cluster.team02_eks
  ]
}

# ==========================================
# EKS Node Group Security Group
# ==========================================

# Create Security Group - EKS Node Group
resource "aws_security_group" "eks_node_group" {
  name        = "team02-eks-node-group-sg"
  description = "Security group for EKS managed nodes"
  vpc_id      = aws_vpc.team02_vpc.id

  ingress {
    description = "Allow all node to node communication"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  ingress {
    description = "Allow pods to receive HTTPS from the control plane"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.team02_vpc.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "team02-eks-node-group-sg"
  }
}

# ==========================================
# EKS OIDC Provider
# ==========================================

# Get TLS Certificate - EKS
data "tls_certificate" "eks" {
  url = aws_eks_cluster.team02_eks.identity[0].oidc[0].issuer
}

# Create IAM OpenID Connect Provider - EKS
resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.team02_eks.identity[0].oidc[0].issuer

  tags = {
    Name = "team02-eks-oidc-provider"
  }
}

# ==========================================
# AWS Auth ConfigMap for EKS
# ==========================================

resource "kubernetes_config_map" "aws_auth" {
  metadata {
    name      = "aws-auth"
    namespace = "kube-system"
  }

  data = {
    mapRoles = yamlencode([
      {
        rolearn  = aws_iam_role.eks_node_group_role.arn
        username = "system:node:{{EC2PrivateDNSName}}"
        groups   = ["system:bootstrappers", "system:nodes"]
      }
    ])

    mapUsers = yamlencode([
      {
        userarn  = var.eks_admin_user_arn
        username = "team02-dev"
        groups   = ["system:masters"]
      }
    ])
  }

  depends_on = [
    aws_eks_cluster.team02_eks
  ]
}