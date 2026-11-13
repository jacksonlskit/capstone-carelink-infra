# Runbook: recover after the nightly AWS cleanup

**Scenario.** The shared sandbox account is cleaned by `aws-nuke` (role `AWSNukeAdminRole`) every day at about 06:00 SGT (22:00 UTC). Resources tagged `Project = capstone-project-group-03` are skipped, but the cleanup checks some things on their own, not through their tagged parent, so they are removed every night:

| Removed every night | Effect | Restored by |
|---|---|---|
| Terraform state files (objects in the tagged state bucket) | Terraform no longer knows what exists; a normal apply would try to create everything again | `scripts/recover-state.sh` (runs inside the infra pipeline) |
| IAM policy attachments and inline policies on our roles | Pipelines cannot reach AWS; load balancer controller and external-dns get `AccessDenied`; new pods cannot pull images | step 1 (GitHub roles) and step 2 (all other roles) |
| CloudWatch dashboard, RDS event subscription | Dashboard missing, no RDS event emails | step 2 |

Protected since 2026-11-13 by tags in `infra/node-tags.tf`: the EKS cluster security group, the node group's Auto Scaling group and its launch template. Without those tags the cleanup removed the security group's rules (ALB returned 504) and the launch template (node group `DEGRADED`).

The cleanup is paused on 27 and 28 November.

## Detection

- `https://carelink-staging.sctp-sandbox.com` returns 504, or a pipeline fails at "Configure AWS Credentials" / "Terraform Init" with 403.
- State is gone when this prints nothing:
  ```bash
  aws s3 ls s3://carelink-infra-state-us-east-1-255945442255 --recursive
  ```
- Roles lost their policies when this prints `0`:
  ```bash
  aws iam list-attached-role-policies --role-name carelink-github-staging-role --query 'length(AttachedPolicies)'
  ```

## Recovery (each morning, about 20 minutes)

1. **GitHub pipeline roles** (needs the bootstrap state on the DevSecOps engineer's laptop):
   ```bash
   cd oicd-bootstrap && terraform apply
   ```
   Expect 2 to add: the `AdministratorAccess` attachments of the staging and production roles.

2. **Everything else: run the infra pipeline.**
   ```bash
   gh workflow run cd.yaml --ref main
   ```
   In each environment the step "Recover state if the nightly cleanup deleted it" finds what still exists and writes import blocks; the apply then adopts those resources and re-creates what the cleanup removed. A healthy morning run has this shape (exact numbers vary):
   ```
   Found 78 of 88 planned resources already in AWS (import blocks written).
   Plan: 78 to import, 10 to add, 12 to change, 0 to destroy.
   ```
   The "to add" are what the cleanup removed (IAM policy attachments, dashboard, RDS event subscription) plus the protection tags. The "to change" are settings Terraform only keeps in its state after an import (for example `force_delete`, `deletion_window_in_days`) and a Helm upgrade with unchanged values. **Stop and investigate if the plan shows anything "to destroy" or "must be replaced"**, or if "Found 0 of N" appears while the clusters still exist.
   Production waits for approval in the Actions tab.

3. **Verify.**
   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' https://carelink-staging.sctp-sandbox.com/actuator/health   # 200
   kubectl get nodes                                                                                   # all Ready
   aws eks describe-nodegroup --cluster-name carelink-staging-eks \
     --nodegroup-name "$(aws eks list-nodegroups --cluster-name carelink-staging-eks --query 'nodegroups[0]' --output text)" \
     --query nodegroup.status                                                                          # ACTIVE
   ```

## If something is still broken

| Symptom | Cause | Fix |
|---|---|---|
| Apply fails with `AlreadyExists` for a KMS alias or an `eks-nodes` role | Leftover pointing at a key the cleanup scheduled for deletion, or an orphaned role | `scripts/clean-wipe-leftovers.sh` (dry run), then `--apply`, then re-run the pipeline |
| ALB still 504 after the roles are back | The load balancer controller skips re-adding its security group rule | `kubectl -n staging annotate targetgroupbinding --all elbv2.k8s.aws/checkpoint- elbv2.k8s.aws/checkpoint-timestamp-` |
| Cluster security group has 0 rules | It lost its `Project` tag, or the tag was added after the cleanup ran | Re-add the two EKS default rules (all traffic from the group itself; all outbound), then re-run the pipeline so the tag is back |
| Node group `DEGRADED`, `Ec2LaunchTemplateNotFound` | Launch template was deleted | A node group cannot get a new launch template: replace it. `terraform apply -replace=aws_eks_node_group.main` (new nodes are created before the old ones are drained) |
| `recover-state.sh` reports "no lookup defined for <type>" | A new resource type was added to Terraform | Add a `case` for it in `scripts/generate-imports.sh` |

## Why not just protect the state?

`aws-nuke` filters S3 objects by the object's own properties, not the bucket's tags, and IAM policy attachments are separate resources that cannot carry tags. Only the cleanup's own configuration can exempt them. Until then the pipeline rebuilds the state from what exists; a rebuild from nothing (`Found 0`, everything "to add") also still works.

## Escalation

If the plan wants to destroy or replace a database, the VPC or the cluster: do not approve. Compare `infra/imports.auto.tf` from the run log with the AWS console, and ask the Solutions Architect before applying.
