# Capstone CareLink — Cloud Infrastructure & OIDC Foundation

Production-grade Infrastructure-as-Code (IaC) repository managing the automated AWS cloud infrastructure, keyless OpenID Connect (OIDC) identity federation, and GitHub Actions CI/CD pipelines for the CareLink platform.

---

## 1. Architecture Overview



+------------------------------------------+
|             GitHub Platform              |
|  - capstone-carelink-infra               |
|  - capstone-carelink-app                 |
+--------------------+---------------------+
|
| Short-Lived OIDC JWT
v
+--------------------+---------------------+
|        AWS IAM OIDC Provider             |
| (token.actions.githubusercontent.com)    |
+--------------------+---------------------+
|
+--------------------------+--------------------------+
| STS:AssumeRoleWithWebIdentity                       |
v                                                     v
+----------------------------+                        +----------------------------+
| carelink-github-staging    |                        | carelink-github-production |
| (AdministratorAccess)      |                        | (AdministratorAccess)      |
+--------------+-------------+                        +--------------+-------------+
|                                                     |
| Deployment & Speculative Plans                      | Gatekeeper Approval Required
v                                                     v
+----------------------------+                        +----------------------------+
|   Staging Infrastructure   |                        | Production Infrastructure  |
+----------------------------+                        +----------------------------+
\                                                     /
-------------------+-------------------------------/
| State Locking (Native S3)
v
+----------------------------+
|   carelink-infra-state-*   |
|   (Terraform 1.10+ Native) |
+----------------------------+


---

## 2. Key Architectural Highlights

* **Keyless OIDC Identity Federation:** Eliminates permanent IAM access keys (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`). GitHub Actions authenticates dynamically using cryptographically signed JSON Web Tokens (JWT) verified by AWS STS.
* **ID-Resilient Subject Matching:** Accommodates GitHub's internal numerical Account ID and Repository ID token injection (`repo:<owner>@<id>/<repo>@<id>:...`) using scoped prefix wildcards (`repo:jacksonlskit*`).
* **Native S3 State Locking (No DynamoDB):** Leverages Terraform `>= 1.10.0` native conditional writes against Amazon S3 (`PutObject` with preconditions), removing DynamoDB costs and operational complexity.
* **Environment-Scoped RBAC:** GitHub Environments (`staging` and `production`) inject their respective `AWS_ROLE_ARN` variables dynamically, ensuring strict boundaries between non-prod and prod assets.
* **Shift-Left Security:** Automated Snyk Infrastructure-as-Code (IaC) vulnerability scanning runs on every Pull Request and acts as a pre-deployment gate before execution.
* **Branch Protection & Rulesets:** GitHub Rulesets enforce pull request approvals, status check verification (`Terraform Plan (staging)`, `Terraform Plan (production)`), and prevent forced pushes/branch deletions on `main`.

---

## 3. Directory Layout

## Repository Structure

```text
capstone-carelink-infra/
├── .github/
│   └── workflows/
│       ├── ci.yml                     # PR verification: Lint, Snyk IaC scan, Speculative Plans
│       ├── cd.yml                     # Delivery: Apply Staging, Reviewer Approval Gate, Apply Prod
│       └── sre.yml                    # Observability: Scheduled CloudWatch alarms & log audits
│
├── adrs/                              # Phase 1: Architecture Decision Records (Minimum 4)
│   ├── 0001-container-runtime-eks.md  # ADR: Selection of Amazon EKS over Amazon ECS
│   ├── 0002-keyless-oidc-security.md  # ADR: GitHub Actions OIDC vs long-lived IAM keys
│   ├── 0003-native-s3-state-locks.md  # ADR: Terraform 1.10+ native S3 locks vs DynamoDB
│   └── 0004-database-availability.md  # ADR: Multi-AZ RDS & automated backup retention
│
├── docs/                              # Capstone Deliverables & Operational Documentation
│   ├── architecture-diagram.png       # Live end-to-end architecture diagram
│   ├── compliance-mapping.md          # Hard constraint compliance mapping matrix
│   ├── monthly-cost-estimate.md       # Running monthly cost estimate for AWS resources
│   └── incident-runbook.md            # SRE runbook for failover & incident response
│
├── environments/                      # Environment-specific variable overrides
│   ├── staging.tfvars                 # Staging configuration (single NAT, db.t4g.small)
│   └── production.tfvars              # Production configuration (Multi-AZ, high availability)
│
├── backend.tf                         # Empty S3 backend declaration (injected via CI/CD)
├── providers.tf                       # AWS, Kubernetes, and Helm provider constraints
├── variables.tf                       # Input variable declarations
├── outputs.tf                         # Output values (EKS cluster endpoint, RDS endpoints, ECR URLs)
│
├── vpc.tf                             # Multi-AZ VPC: 3 Public & 3 Private Subnets + NAT Gateways
├── kms.tf                             # Customer Managed Keys (CMK) for EBS, RDS, and Secrets
├── eks.tf                             # EKS Cluster (v1.30), OIDC IRSA provider, Managed Node Groups
├── eks-access.tf                      # EKS Access Entries & Policies for GitHub Actions OIDC roles
├── ecr.tf                             # Amazon ECR repositories for all 4 microservices
├── rds.tf                             # Multi-AZ RDS MySQL/PostgreSQL in private subnets (KMS encrypted)
├── monitoring.tf                      # CloudWatch Alarms, SNS alert topics, and SRE Dashboard
│
├── .gitignore                         # Git exclusion rules (.terraform/, *.tfstate)
└── README.md                          # Repository documentation, setup, and runbooks


4. Workflows & Pipelines

Pipeline	Target File	Trigger	Purpose
CI (PR Verification)	.github/workflows/ci.yml	pull_request to main	Validates formatting (terraform fmt), runs Snyk IaC scan, and runs speculative plans for Staging and Production.
CD (Delivery)	.github/workflows/cd.yml	push to main	Pre-deployment Snyk check, automatic deploy to Staging, manual reviewer approval gate, deploy to Production.
SRE (Observability)	.github/workflows/sre.yml	Cron (0 */6 * * *) & Manual	Queries active CloudWatch alarms in ALARM status and inspects recent log groups in us-east-1.

5. Security & Trust Policy Specifications

The GitHub Actions Subject Claim Structure

GitHub Actions emits OIDC tokens formatted with internal account and repository IDs:

repo:<github_owner>@<github_user_id>/<repo_name>@<repo_id>:environment:<environment_name>


AWS IAM Trust Relationship

To guarantee that tokens are accepted while remaining strictly isolated to the authorized owner account, the trust policy enforces:

{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": [
            "repo:jacksonlskit*capstone-carelink-infra*",
            "repo:jacksonlskit*capstone-carelink-app*",
            "repo:jacksonlskit*"
          ]
        }
      }
    }
  ]
}


6. Initial Bootstrapping & Setup

Because CI/CD pipelines rely on the IAM roles to authenticate, the bootstrap layer must be provisioned once from a local administrative workstation.

Prerequisites

⚬ Terraform CLI >= 1.10.0
⚬ AWS CLI authenticated with local Administrator access
⚬ GitHub Personal Access Token (Classic) with repo, admin:repo_hook, and workflow scopes

Step 1: Deploy Bootstrap Infrastructure

cd bootstrap

# Export GitHub token for the GitHub Terraform provider
export GITHUB_TOKEN="ghp_yourPersonalAccessTokenHere"

# Initialize and deploy
terraform init
terraform apply


This provisions:

1. The AWS IAM OpenID Connect Provider (token.actions.githubusercontent.com).
2. The remote S3 state bucket with AES256 encryption, bucket versioning, and public access blocks.
3. IAM Roles: carelink-github-staging-role and carelink-github-production-role.
4. GitHub Environments: staging and production (with manual approval gate on production).
5. GitHub Environment Variables: AWS_ROLE_ARN pointing to the respective IAM roles.
6. GitHub Global Variables: AWS_REGION and TF_STATE_BUCKET.
7. GitHub Branch Protection Rulesets for main.

Step 2: Configure Repository Secrets

To enable automated security scans:

1. Navigate to Settings > Secrets and variables > Actions on capstone-carelink-infra.
2. Click New repository secret.
3. Name: SNYK_TOKEN
4. Value: Paste your Snyk API Token.

7. Operating & Deployment Procedures

Making Infrastructure Changes

1. Create a feature branch:
   git checkout -b feature/my-infrastructure-update
   
2. Commit changes and push to GitHub:
   git add .
   git commit -m "feat: add new resource"
   git push origin feature/my-infrastructure-update
   
3. Open a Pull Request targeting main.
4. Review the automated status checks in GitHub Actions:
  ⚬ Terraform Lint & Validate
  ⚬ Snyk IaC Security Scan
  ⚬ Terraform Plan (staging)
  ⚬ Terraform Plan (production)
5. Once approved and checks pass, merge the Pull Request.

Production Promotion

1. Merging to main triggers .github/workflows/cd.yml.
2. Staging applies automatically.
3. The pipeline halts at the Deploy to Production stage.
4. Go to Actions > Select the active run > Click Review deployments > Select production > Click Approve and deploy.

Running Ad-Hoc SRE Diagnostics

1. Go to Actions > SRE: Health & Monitoring Check.
2. Click Run workflow > Select branch main.
3. Check the output logs for active alarms or CloudWatch log group statistics.