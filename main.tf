data "aws_eks_cluster" "cluster" {
  name = var.cluster_name
}

data "aws_ami" "eks_ami" {
  most_recent = true

  filter {
    name   = "name"
    values = ["amazon-eks-node-${data.aws_eks_cluster.cluster.version}-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["amazon"]
}

# Required if instance profile is provided by user
data "aws_iam_instance_profile" "eks_ng_vm_profile" {
  count = var.create_node_iam_profile ? 0 : 1
  name  = var.node_iam_profile
}

resource "aws_iam_instance_profile" "eks_ng_vm_profile" {
  count       = var.create_node_iam_profile ? 1 : 0
  name_prefix = "${var.cluster_name}-ng-profile-"
  role        = join(", ", aws_iam_role.eks_ng_role.*.name)
}

resource "aws_iam_role" "eks_ng_role" {
  count                 = var.create_node_iam_profile ? 1 : 0
  name_prefix           = "${var.cluster_name}-ng-role-"
  force_detach_policies = true

  assume_role_policy = jsonencode({
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
    Version = "2012-10-17"
  })
}

resource "aws_iam_role_policy_attachment" "ng_worker_policy" {
  count      = var.create_node_iam_profile ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = join(", ", aws_iam_role.eks_ng_role.*.name)
}

resource "aws_iam_role_policy_attachment" "ng_cni_policy" {
  count      = var.create_node_iam_profile ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = join(", ", aws_iam_role.eks_ng_role.*.name)
}

resource "aws_iam_role_policy_attachment" "ng_registry_policy" {
  count      = var.create_node_iam_profile ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = join(", ", aws_iam_role.eks_ng_role.*.name)
}

# Policy required for cluster autoscaling
resource "aws_iam_role_policy" "eks_scaling_policy" {
  count       = var.create_node_iam_profile ? 1 : 0
  name_prefix = "${var.cluster_name}-ng-role-policy-"
  role        = join(", ", aws_iam_role.eks_ng_role.*.id)

  policy = <<-EOF
  {
    "Version": "2012-10-17",
    "Statement": [
      {
        "Action": [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances",
          "autoscaling:DescribeLaunchConfigurations",
          "autoscaling:DescribeTags",
          "autoscaling:SetDesiredCapacity",
          "autoscaling:TerminateInstanceInAutoScalingGroup",
          "ec2:DescribeLaunchTemplateVersions"
        ],
        "Effect": "Allow",
        "Resource": "*"
      }
    ]
  }
  EOF
}

resource "aws_security_group" "eks_ng_sg" {
  # checkov:skip=CKV2_AWS_5: Security group gets associated with EKS nodes
  count       = length(var.ng_sg_ids) == 0 ? 1 : 0
  name_prefix = "${var.cluster_name}-ng-sg-"
  vpc_id      = local.vpc_id
  description = "Security group for ${var.cluster_name} worker nodes"
  tags        = var.tags
}

resource "aws_security_group_rule" "node_to_node" {
  count                    = length(var.ng_sg_ids) == 0 ? 1 : 0
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  description              = "Allow node to communicate with each other"
  source_security_group_id = join(",", aws_security_group.eks_ng_sg.*.id)
  security_group_id        = join(", ", aws_security_group.eks_ng_sg.*.id)
}

resource "aws_security_group_rule" "pods_to_control_plane" {
  count                    = length(var.ng_sg_ids) == 0 ? 1 : 0
  type                     = "ingress"
  from_port                = 1025
  to_port                  = 65535
  protocol                 = "tcp"
  description              = "Allow worker Kubelets and pods to receive communication from the cluster control plane"
  source_security_group_id = local.cluster_sg_id
  security_group_id        = join(", ", aws_security_group.eks_ng_sg.*.id)
}

resource "aws_security_group_rule" "control_plane_to_pods" {
  count                    = length(var.ng_sg_ids) == 0 ? 1 : 0
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  description              = "Allow pods running extension API servers on port 443 to receive communication from cluster control plane"
  source_security_group_id = local.cluster_sg_id
  security_group_id        = join(", ", aws_security_group.eks_ng_sg.*.id)
}

resource "aws_security_group_rule" "eks_ng_egress" {
  count             = length(var.ng_sg_ids) == 0 ? 1 : 0
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = join(", ", aws_security_group.eks_ng_sg.*.id)
  description       = "Allow all outgoing connections"
}

resource "aws_security_group_rule" "eks_ng_ssh" {
  # checkov:skip=CKV_AWS_24: Restricting SSH access to world for EKS nodes depends on user
  count                    = length(var.ng_sg_ids) == 0 && var.ssh_key_name != "" ? 1 : 0
  type                     = "ingress"
  from_port                = 22
  to_port                  = 22
  protocol                 = "tcp"
  description              = "Allow SSH connection to node"
  source_security_group_id = var.ssh_source_sg_id == "" ? null : var.ssh_source_sg_id
  cidr_blocks              = var.ssh_source_sg_id == "" ? var.ssh_cidr_blocks : null
  security_group_id        = join(", ", aws_security_group.eks_ng_sg.*.id)
}

resource "aws_security_group_rule" "cluster_sg" {
  count                    = length(var.ng_sg_ids) == 0 ? 1 : 0
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  description              = "Allow pods to communicate with the cluster API Server"
  source_security_group_id = join(", ", aws_security_group.eks_ng_sg.*.id)
  security_group_id        = local.cluster_sg_id
}

locals {
  vpc_id           = data.aws_eks_cluster.cluster.vpc_config.0.vpc_id
  cluster_sg_id    = data.aws_eks_cluster.cluster.vpc_config.0.cluster_security_group_id
  node_iam_profile = var.create_node_iam_profile ? join(", ", aws_iam_instance_profile.eks_ng_vm_profile.*.name) : var.node_iam_profile
  node_role_name   = var.create_node_iam_profile ? join(", ", aws_iam_role.eks_ng_role.*.name) : join(", ", data.aws_iam_instance_profile.eks_ng_vm_profile.*.role_name)
  node_role_arn    = var.create_node_iam_profile ? join(", ", aws_iam_role.eks_ng_role.*.arn) : join(", ", data.aws_iam_instance_profile.eks_ng_vm_profile.*.role_arn)
  node_sg_ids      = length(var.ng_sg_ids) == 0 ? aws_security_group.eks_ng_sg.*.id : var.ng_sg_ids
}

data "aws_kms_key" "eks_ng_key" {
  key_id = var.kms_key
}

data "template_file" "user_data" {
  template = file("${path.module}/user-data.tpl")

  vars = {
    CLUSTER_NAME         = var.cluster_name
    BOOTSTRAP_ARGS       = var.bootstrap_args
    ADDITIONAL_USER_DATA = base64decode(var.user_data_base64)
  }
}

resource "aws_launch_template" "eks_ng_template" {
  count       = var.use_spot_instances ? 0 : 1
  name_prefix = var.ng_name == "" ? "${var.cluster_name}-ng-template-" : null
  name        = var.ng_name == "" ? null : "${var.ng_name}-template"

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = var.volume_size
      delete_on_termination = true
      encrypted             = var.encrypt_volume
      kms_key_id            = var.encrypt_volume == true ? data.aws_kms_key.eks_ng_key.arn : null
      volume_type           = var.volume_type
      iops                  = var.volume_type == "io1" ? var.iops : null
    }
  }

  iam_instance_profile {
    name = local.node_iam_profile
  }

  image_id               = var.ami_id == "" ? data.aws_ami.eks_ami.image_id : var.ami_id
  instance_type          = var.instance_type
  key_name               = var.ssh_key_name == "" ? null : var.ssh_key_name
  vpc_security_group_ids = local.node_sg_ids

  metadata_options {
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
    http_tokens                 = "required"
  }

  user_data = base64encode(data.template_file.user_data.rendered)

  lifecycle {
    create_before_destroy = true
  }

  tags = var.tags
}

resource "aws_launch_template" "eks_ng_spot_template" {
  count       = var.use_spot_instances ? 1 : 0
  name_prefix = var.ng_name == "" ? "${var.cluster_name}-ng-template-" : null
  name        = var.ng_name == "" ? null : "${var.ng_name}-template"

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = var.volume_size
      delete_on_termination = true
      encrypted             = var.encrypt_volume
      kms_key_id            = var.encrypt_volume == true ? data.aws_kms_key.eks_ng_key.arn : null
      volume_type           = var.volume_type
      iops                  = var.volume_type == "io1" ? var.iops : null
    }
  }

  iam_instance_profile {
    name = local.node_iam_profile
  }

  image_id               = var.ami_id == "" ? data.aws_ami.eks_ami.image_id : var.ami_id
  instance_type          = var.instance_type
  key_name               = var.ssh_key_name == "" ? null : var.ssh_key_name
  vpc_security_group_ids = local.node_sg_ids

  metadata_options {
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
    http_tokens                 = "required"
  }

  user_data = base64encode(data.template_file.user_data.rendered)

  lifecycle {
    create_before_destroy = true
  }

  instance_market_options {
    market_type = var.use_spot_instances ? "spot" : null

    spot_options {
      block_duration_minutes         = var.spot_block_duration_minutes == 0 ? null : var.spot_block_duration_minutes
      instance_interruption_behavior = var.spot_interruption_behavior == "" ? "terminate" : var.spot_interruption_behavior
      max_price                      = var.spot_max_price == 0 ? null : var.spot_max_price
      spot_instance_type             = var.spot_type == "" ? null : var.spot_type
      valid_until                    = var.spot_expiry == "" ? null : var.spot_expiry
    }
  }

  tags = var.tags
}

locals {
  ng_id   = var.use_spot_instances ? join(", ", aws_launch_template.eks_ng_spot_template.*.id) : join(", ", aws_launch_template.eks_ng_template.*.id)
  ng_name = var.use_spot_instances ? join(", ", aws_launch_template.eks_ng_spot_template.*.name) : join(", ", aws_launch_template.eks_ng_template.*.name)
}

resource "aws_autoscaling_group" "eks_ng_asg" {
  name_prefix      = var.ng_name == "" ? "${var.cluster_name}-ng-asg-" : null
  name             = var.ng_name == "" ? null : "${var.ng_name}-asg"
  max_size         = var.max_size
  min_size         = var.min_size
  desired_capacity = var.desired_size

  launch_template {
    id      = local.ng_id
    version = "$Latest"
  }

  vpc_zone_identifier = var.subnet_ids

  tag {
    key                 = "Name"
    value               = "${local.ng_name}-node"
    propagate_at_launch = true
  }
  tag {
    key                 = "kubernetes.io/cluster/${var.cluster_name}"
    value               = "owned"
    propagate_at_launch = true
  }
  tag {
    key                 = "k8s.io/cluster-autoscaler/${var.cluster_name}"
    value               = "owned"
    propagate_at_launch = true
  }
  tag {
    key                 = "k8s.io/cluster-autoscaler/enabled"
    value               = "true"
    propagate_at_launch = true
  }

  dynamic "tag" {
    for_each = var.tags

    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    create_before_destroy = true
    ignore_changes = [
      desired_capacity
    ]
  }
}
