terraform {
  backend "s3" {

    bucket         = "my-s3-terraformstate-bucket"
    key            = "dictionary-deployment/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-locks"

  }
}

provider "aws" {
  region = "us-east-1"

}

resource "aws_vpc" "dictionary_vpc" {
  cidr_block = "10.0.0.0/16"

  tags = {
    Name = "dictionary-vpc"
  }

}

resource "aws_subnet" "dictionary_subnet_a" {
  vpc_id                  = aws_vpc.dictionary_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true

  tags = {
    Name                                           = "dictionary-subnet-a"
    "kubernetes.io/cluster/dictionary-eks-cluster" = "shared"
    "kubernetes.io/role/elb"                       = "1"
  }

}


resource "aws_subnet" "dictionary_subnet_b" {
  vpc_id                  = aws_vpc.dictionary_vpc.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "us-east-1b"
  map_public_ip_on_launch = true

  tags = {
    Name                                           = "dictionary-subnet-b"
    "kubernetes.io/cluster/dictionary-eks-cluster" = "shared"
    "kubernetes.io/role/elb"                       = "1"
  }

}


resource "aws_internet_gateway" "dictionary_gw" {
  vpc_id = aws_vpc.dictionary_vpc.id

  tags = {
    Name = "dictionary-internet-gateway"
  }
}


resource "aws_route_table" "dictionary_route_table" {
  vpc_id = aws_vpc.dictionary_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.dictionary_gw.id
  }

  tags = {
    Name = "dictionary-route-table"
  }
}

resource "aws_route_table_association" "dictionary_rta-a" {
  subnet_id      = aws_subnet.dictionary_subnet_a.id
  route_table_id = aws_route_table.dictionary_route_table.id

}
resource "aws_route_table_association" "dictionary_rta-b" {
  subnet_id      = aws_subnet.dictionary_subnet_b.id
  route_table_id = aws_route_table.dictionary_route_table.id

}
resource "aws_iam_role" "eks_cluster_role" {
  name = "dictionary-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster_role.name
}

resource "aws_eks_cluster" "dictionary_cluster" {
  name     = "dictionary-eks-cluster"
  role_arn = aws_iam_role.eks_cluster_role.arn

  vpc_config {
    subnet_ids = [
      aws_subnet.dictionary_subnet_a.id,
      aws_subnet.dictionary_subnet_b.id
    ]
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy
  ]
}

resource "aws_iam_role" "eks_node_role" {
  name = "dictionary-eks-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_node_role.name
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.eks_node_role.name
}

resource "aws_iam_role_policy_attachment" "ec2_container_registry_readonly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.eks_node_role.name
}

resource "aws_eks_node_group" "dictionary_nodes" {
  cluster_name    = aws_eks_cluster.dictionary_cluster.name
  node_group_name = "dictionary-node-group"
  node_role_arn   = aws_iam_role.eks_node_role.arn

  subnet_ids = [
    aws_subnet.dictionary_subnet_a.id,
    aws_subnet.dictionary_subnet_b.id
  ]

  scaling_config {
    desired_size = 2
    max_size     = 2
    min_size     = 1
  }

  instance_types = ["t3.small"]

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.ec2_container_registry_readonly
  ]
}



