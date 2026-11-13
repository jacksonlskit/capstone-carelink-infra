terraform {
  required_version = ">= 1.10.0"

  # bucket, key and region are passed by `terraform init -backend-config=...`
  # (pipelines) or environments/<env>/backend.hcl (laptops).
  backend "s3" {
    # Native S3 state locking (ADR 0003): every plan and apply first creates
    # <key>.tflock with a conditional write; a second run on the same state
    # gets "Error acquiring the state lock" (or waits with -lock-timeout)
    # instead of reading or writing a half-applied state. Set here, not only in
    # backend.hcl, because the pipelines do not use backend.hcl.
    use_lockfile = true
  }
}
