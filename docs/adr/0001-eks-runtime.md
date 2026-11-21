# ADR 0001: Run the application on Amazon EKS

- **Status:** Accepted
- **Date:** 2026-11-22 (records a decision taken when the platform was built in October)
- **Owner:** Solutions Architect with DevOps Engineer

## Context
CareLink is demonstrated with Spring PetClinic Cloud: an API gateway and three services (customers, vets, visits) on a shared MySQL database. The upstream project runs on Kubernetes and uses Spring Cloud Kubernetes for configuration and service discovery. The brief requires no single point of failure in the application tier, surviving the loss of one application instance, separate staging and production environments, and a deployed system that matches its code.

## Decision
- One **Amazon EKS** cluster per environment (`carelink-staging-eks`, `carelink-production-eks`, `infra/eks.tf`), version set by `eks_cluster_version`.
- A managed node group over the three private subnets (three AZs): `t3.medium`, desired 4, min 3, max 6, sized from measured use (memory and pod slots limit, not CPU). A Terraform launch template encrypts root volumes with the `ebs` KMS key and requires IMDSv2.
- Cluster access through EKS access entries, per environment (`cluster_access`): in production only the DevOps owner and the pipeline role are cluster admins.
- Add-ons installed by Terraform: EBS CSI driver, AWS Load Balancer Controller, external-dns, External Secrets, Reloader and Argo CD (ADR 0008).

## Alternatives considered
- **ECS on Fargate:** less to operate and no nodes to size, but the app relies on Kubernetes for configuration and discovery, and we would lose GitOps with Argo CD and the Kubernetes primitives we use for availability (topology spread, PodDisruptionBudgets).
- **One shared cluster with a namespace per environment:** cheaper (one control plane), but a staging change could affect production, which conflicts with environment isolation (ADR 0006).

## Consequences
- Two control planes cost about $0.10/h each, the largest fixed cost after the nodes.
- Two replicas per service are spread over nodes (hard rule) and zones (preference), with PodDisruptionBudgets, so losing one node or instance leaves every service running.
- More components to operate and upgrade; EKS upgrades go one minor version at a time.
- Pod slots (17 per `t3.medium` with the VPC CNI) and memory are the sizing limits: adding workloads such as a monitoring stack needs capacity planning.
