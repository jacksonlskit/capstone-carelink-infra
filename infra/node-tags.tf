# ==============================================================================
# Cleanup-protection tag for the worker nodes
# ------------------------------------------------------------------------------
# EKS creates the managed node group's Auto Scaling group itself, so neither the
# node group's tags nor the provider's default_tags reach that Auto Scaling
# group or the EC2 instances it launches. Without the Project tag the nightly
# cleanup may remove them, and the cluster loses its nodes.
#
# This tags the Auto Scaling group and, with propagate_at_launch, every instance
# it launches from now on. Instances already running get the tag the next time
# they are replaced (node group update, scale-out, or a terminated instance
# being replaced by the Auto Scaling group).
# ==============================================================================
resource "aws_autoscaling_group_tag" "nodes_project" {
  autoscaling_group_name = aws_eks_node_group.main.resources[0].autoscaling_groups[0].name

  tag {
    key                 = "Project"
    value               = var.cohort_project_tag
    propagate_at_launch = true
  }
}
