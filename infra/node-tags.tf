# ==============================================================================
# Cleanup-protection tags for resources that EKS creates by itself
# ------------------------------------------------------------------------------
# The provider's default_tags only reach resources Terraform creates. EKS creates
# three things on its own, without our Project tag, and the instructors' nightly
# cleanup (aws-nuke) treats untagged resources as fair game:
#
#   1. the node group's Auto Scaling group   -> nodes would be terminated
#   2. the node group's launch template      -> node group goes DEGRADED
#                                               (Ec2LaunchTemplateNotFound) and
#                                               cannot replace or add nodes
#   3. the cluster security group            -> its rules are removed, so the
#                                               ALB cannot reach pods (HTTP 504)
#                                               and nodes lose connectivity
#
# All three happened on 2026-11-13. These resources add the tag afterwards.
#
# What tags cannot protect (the cleanup checks them on their own, not through
# their parent): IAM policy attachments and the Terraform state objects in S3.
# Those are restored by re-running the infra pipeline, see
# scripts/recover-state.sh.
# ==============================================================================

# 1. Auto Scaling group, and every instance it launches from now on.
#    Instances already running get the tag the next time they are replaced.
resource "aws_autoscaling_group_tag" "nodes_project" {
  autoscaling_group_name = aws_eks_node_group.main.resources[0].autoscaling_groups[0].name

  tag {
    key                 = "Project"
    value               = var.cohort_project_tag
    propagate_at_launch = true
  }
}

# 2. Launch template. EKS always generates its own launch template for a managed
#    node group; its ID is only visible on the Auto Scaling group.
data "aws_autoscaling_group" "nodes" {
  name = aws_eks_node_group.main.resources[0].autoscaling_groups[0].name
}

locals {
  node_launch_template_id = try(
    data.aws_autoscaling_group.nodes.mixed_instances_policy[0].launch_template[0].launch_template_specification[0].launch_template_id,
    data.aws_autoscaling_group.nodes.launch_template[0].id,
  )
}

resource "aws_ec2_tag" "node_launch_template_project" {
  resource_id = local.node_launch_template_id
  key         = "Project"
  value       = var.cohort_project_tag
}

# 3. Cluster security group (created by EKS, attached to the control plane and
#    every node).
resource "aws_ec2_tag" "cluster_security_group_project" {
  resource_id = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  key         = "Project"
  value       = var.cohort_project_tag
}
