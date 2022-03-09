locals {
  port = coalesce(var.port, (var.engine == "aurora-postgresql" ? 5432 : 3306))

  db_subnet_group_name          = var.create_db_subnet_group ? join("", aws_db_subnet_group.this.*.name) : var.db_subnet_group_name
  internal_db_subnet_group_name = try(coalesce(var.db_subnet_group_name, var.name), "")
  master_password               = var.create_cluster && var.create_random_password ? random_password.master_password[0].result : var.master_password
  backtrack_window              = (var.engine == "aurora-mysql" || var.engine == "aurora") && var.engine_mode != "serverless" ? var.backtrack_window : 0

  rds_enhanced_monitoring_arn = var.create_monitoring_role ? join("", aws_iam_role.rds_enhanced_monitoring.*.arn) : var.monitoring_role_arn
  rds_security_group_id       = join("", aws_security_group.this.*.id)
  is_serverless               = var.engine_mode == "serverless"
}

# Ref. https://docs.aws.amazon.com/general/latest/gr/aws-arns-and-namespaces.html#genref-aws-service-namespaces
data "aws_partition" "current" {}

# Random string to use as master password
resource "random_password" "master_password" {
  count = var.create_cluster && var.create_random_password ? 1 : 0

  length  = var.random_password_length
  special = false
}

resource "random_id" "snapshot_identifier" {
  count = var.create_cluster ? 1 : 0

  keepers = {
    id = var.name
  }

  byte_length = 4
}

resource "aws_db_subnet_group" "this" {
  count = var.create_cluster && var.create_db_subnet_group ? 1 : 0

  name        = local.internal_db_subnet_group_name
  description = "For Aurora cluster ${var.name}"
  subnet_ids  = var.subnets

  tags = var.tags
}

# TODO: aws_rds_cluster resources in destroy-safeguard.tf used to be here, moved there to isolate the necessary. Read its file header for explanation.

# TODO: aws_rds_cluster_instance resources in destroy-safeguard.tf used to be here, moved there to isolate the necessary. Read its file header for explanation.

resource "aws_rds_cluster_endpoint" "this" {
  for_each = var.create_cluster && !local.is_serverless ? var.endpoints : tomap({})

  cluster_identifier          = try(aws_rds_cluster.this[0].id, "")
  cluster_endpoint_identifier = each.value.identifier
  custom_endpoint_type        = each.value.type

  static_members   = lookup(each.value, "static_members", null)
  excluded_members = lookup(each.value, "excluded_members", null)

  depends_on = [
    aws_rds_cluster_instance.this
  ]

  tags = merge(var.tags, lookup(each.value, "tags", {}))
}

resource "aws_rds_cluster_role_association" "this" {
  for_each = var.create_cluster ? var.iam_roles : {}

  db_cluster_identifier = try(aws_rds_cluster.this[0].id, "")
  feature_name          = each.value.feature_name
  role_arn              = each.value.role_arn
}

################################################################################
# Enhanced Monitoring
################################################################################

data "aws_iam_policy_document" "monitoring_rds_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["monitoring.rds.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "rds_enhanced_monitoring" {
  count = var.create_cluster && var.create_monitoring_role && var.monitoring_interval > 0 ? 1 : 0

  name        = var.iam_role_use_name_prefix ? null : var.iam_role_name
  name_prefix = var.iam_role_use_name_prefix ? "${var.iam_role_name}-" : null
  description = var.iam_role_description
  path        = var.iam_role_path

  assume_role_policy    = data.aws_iam_policy_document.monitoring_rds_assume_role.json
  managed_policy_arns   = var.iam_role_managed_policy_arns
  permissions_boundary  = var.iam_role_permissions_boundary
  force_detach_policies = var.iam_role_force_detach_policies
  max_session_duration  = var.iam_role_max_session_duration

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "rds_enhanced_monitoring" {
  count = var.create_cluster && var.create_monitoring_role && var.monitoring_interval > 0 ? 1 : 0

  role       = aws_iam_role.rds_enhanced_monitoring[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

################################################################################
# Autoscaling
################################################################################

resource "aws_appautoscaling_target" "this" {
  count = var.create_cluster && var.autoscaling_enabled && !local.is_serverless ? 1 : 0

  max_capacity       = var.autoscaling_max_capacity
  min_capacity       = var.autoscaling_min_capacity
  resource_id        = "cluster:${try(aws_rds_cluster.this[0].cluster_identifier, "")}"
  scalable_dimension = "rds:cluster:ReadReplicaCount"
  service_namespace  = "rds"
}

resource "aws_appautoscaling_policy" "this" {
  count = var.create_cluster && var.autoscaling_enabled && !local.is_serverless ? 1 : 0

  name               = "target-metric"
  policy_type        = "TargetTrackingScaling"
  resource_id        = "cluster:${try(aws_rds_cluster.this[0].cluster_identifier, "")}"
  scalable_dimension = "rds:cluster:ReadReplicaCount"
  service_namespace  = "rds"

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = var.predefined_metric_type
    }

    scale_in_cooldown  = var.autoscaling_scale_in_cooldown
    scale_out_cooldown = var.autoscaling_scale_out_cooldown
    target_value       = var.predefined_metric_type == "RDSReaderAverageCPUUtilization" ? var.autoscaling_target_cpu : var.autoscaling_target_connections
  }

  depends_on = [
    aws_appautoscaling_target.this
  ]
}


################################################################################
# Security Group
################################################################################

resource "aws_security_group" "this" {
  count = var.create_cluster && var.create_security_group ? 1 : 0

  name_prefix = "${var.name}-"
  vpc_id      = var.vpc_id
  description = coalesce(var.security_group_description, "Control traffic to/from RDS Aurora ${var.name}")

  tags = merge(var.tags, var.security_group_tags, { Name = var.name })
}

# TODO - change to map of ingress rules under one resource at next breaking change
resource "aws_security_group_rule" "default_ingress" {
  count = var.create_cluster && var.create_security_group ? length(var.allowed_security_groups) : 0

  description = "From allowed SGs"

  type                     = "ingress"
  from_port                = local.port
  to_port                  = local.port
  protocol                 = "tcp"
  source_security_group_id = element(var.allowed_security_groups, count.index)
  security_group_id        = local.rds_security_group_id
}

# TODO - change to map of ingress rules under one resource at next breaking change
resource "aws_security_group_rule" "cidr_ingress" {
  count = var.create_cluster && var.create_security_group && length(var.allowed_cidr_blocks) > 0 ? 1 : 0

  description = "From allowed CIDRs"

  type              = "ingress"
  from_port         = local.port
  to_port           = local.port
  protocol          = "tcp"
  cidr_blocks       = var.allowed_cidr_blocks
  security_group_id = local.rds_security_group_id
}

resource "aws_security_group_rule" "egress" {
  for_each = var.create_cluster && var.create_security_group ? var.security_group_egress_rules : {}

  # required
  type              = "egress"
  from_port         = lookup(each.value, "from_port", local.port)
  to_port           = lookup(each.value, "to_port", local.port)
  protocol          = "tcp"
  security_group_id = local.rds_security_group_id

  # optional
  cidr_blocks              = lookup(each.value, "cidr_blocks", null)
  description              = lookup(each.value, "description", null)
  ipv6_cidr_blocks         = lookup(each.value, "ipv6_cidr_blocks", null)
  prefix_list_ids          = lookup(each.value, "prefix_list_ids", null)
  source_security_group_id = lookup(each.value, "source_security_group_id", null)
}
