# ADR 0001: Compute platform: Amazon EKS

**Status:** Accepted

**Date:** 2026-11-22

## Context
We are a team of four (DevOps, two SRE, database) running CareLink's demonstration application, Spring PetClinic Cloud. It consists of an API gateway and three Spring Boot services (customers, vets, visits) on RDS MySQL. The application was built for Kubernetes: it uses Spring Cloud Kubernetes for its configuration (ConfigMaps) and for service discovery.

The brief requires:
- 99.9% availability in clinic hours (08:00–20:00 SGT);
- no single point of failure in production, and surviving the loss of one application instance, demonstrated live;
- separate staging and production environments;
- everything as code, with a deployed system that matches its code.

We work in a shared cohort AWS account that is cleaned every night, so the platform must come back from Git and Terraform without manual steps. Cost matters, but the hard constraints come first.

## Options Considered
**1. Amazon EKS, one cluster per environment**
- For:
  - Runs the application unchanged (Spring Cloud Kubernetes).
  - Kubernetes gives us the availability features we have to demonstrate: two replicas per service spread over nodes and zones, PodDisruptionBudgets and readiness probes.
  - Argo CD (GitOps) keeps each cluster equal to Git and undoes manual changes, which matches "the deployed system matches its code".
  - The Helm ecosystem covers the rest: AWS Load Balancer Controller, external-dns, External Secrets, Reloader, and our monitoring stack (Prometheus, Loki, Grafana, Alertmanager).
- Against: $73/month per control plane, nodes to size and upgrade, and a steeper learning curve.

**2. Amazon ECS on Fargate**
- For:
  - AWS-native, with no nodes to manage and per-second billing.
  - For the application alone it is cheaper: 8 tasks of 0.25 vCPU / 1 GB cost about $85/month per environment, against about $194 for an EKS control plane plus 4 `t3.medium` nodes. (us-east-1 on-demand prices from the AWS Price List API, 26 Nov 2026.)
- Against:
  - Service discovery and configuration would have to be rebuilt (AWS Cloud Map, or Eureka plus a Config Server), which means changing the application.
  - Deployments are pushed task-definition revisions, with no continuous drift correction.
  - The Helm-based monitoring stack does not apply: metrics and dashboards would move to Container Insights or Amazon Managed Prometheus/Grafana, which are extra services with their own cost.

**3. One shared EKS cluster, with a namespace per environment**
- For: one control plane less ($73/month).
- Against:
  - A staging change (an add-on upgrade, a node problem, a bad manifest) could affect production.
  - Cluster-wide permissions are hard to split per environment.
  - Conflicts with environment isolation (ADR 0006).

**4. AWS Lambda**
- For: no idle cost.
- Against: the services are long-running Spring Boot applications. Java cold starts of several seconds on user requests are unacceptable, and the application would need a rewrite.

## Decision
Amazon EKS, one cluster per environment (`carelink-staging-eks`, `carelink-production-eks`, defined in `infra/eks.tf`). It runs the application as built, gives us the Kubernetes availability features the hard constraints ask us to demonstrate, and lets Argo CD keep both environments equal to Git (ADR 0008).

How it is set up:
- **Nodes:** a managed node group over three private subnets in three AZs: `t3.medium`, desired 4, min 3, max 6, sized from measured memory and pod-slot use. A Terraform launch template encrypts root volumes with the `ebs` KMS key and requires IMDSv2.
- **Access:** EKS access entries, set per environment in `cluster_access`. In production only the DevOps owner and the pipeline role are cluster admins.
- **Add-ons, all installed by Terraform:** EBS CSI driver, AWS Load Balancer Controller, external-dns, External Secrets, Reloader and Argo CD.

## Consequences
**We gain:**
- An application that runs unchanged.
- Availability we can show live: losing a replica or a node keeps every service running, and Grafana shows it.
- Git as the single record of what runs in each environment.
- Recovery after the nightly cleanup with no manual steps.

**We pay:**
- About $73/month per control plane ($146 for both).
- About $110/month more per environment than Fargate would cost for the application alone. We accept this because the same nodes also run the monitoring stack, Argo CD and the controllers.
- Operational work: node sizing (memory, and the 17-pod limit per `t3.medium` with the VPC CNI) and EKS upgrades one minor version at a time.
- Kubernetes-specific problems we had to solve: a rollout that hung because a disk can attach to only one node, and an ALB lookup that broke when a second Ingress appeared.

**We would revisit this decision** if the application did not depend on Kubernetes and the team had no Kubernetes skills. Then ECS on Fargate would be the simpler and cheaper choice.
