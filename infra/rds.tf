locals {
  is_prod = var.environment == "production"

  db_ports = {
    mysql    = 3306
    postgres = 5432
  }
  db_log_exports = {
    mysql    = ["error", "slowquery"]
    postgres = ["postgresql", "upgrade"]
  }
}

resource "aws_db_subnet_group" "main" {
  name       = "${local.name_prefix}-db"
  subnet_ids = aws_subnet.private[*].id

  tags = { Name = "${local.name_prefix}-db-subnet-group" }
}

resource "aws_security_group" "rds" {
  for_each = var.databases

  name        = "${local.name_prefix}-rds-${each.key}"
  description = "Allow ${each.value.engine} access from private subnets only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "${each.value.engine} from private subnets (EKS nodes/pods)"
    from_port   = local.db_ports[each.value.engine]
    to_port     = local.db_ports[each.value.engine]
    protocol    = "tcp"
    cidr_blocks = local.private_subnet_cidrs
  }

  tags = { Name = "${local.name_prefix}-rds-${each.key}-sg" }
}

resource "aws_db_instance" "main" {
  for_each = var.databases

  identifier     = "${local.name_prefix}-${each.key}"
  engine         = each.value.engine
  engine_version = each.value.engine_version
  instance_class = var.db_instance_class

  db_name  = each.value.db_name
  username = "dbadmin"

  # Master password is generated into Secrets Manager (KMS encrypted); never in state/tfvars
  manage_master_user_password   = true
  master_user_secret_kms_key_id = aws_kms_key.this["secrets"].arn

  allocated_storage     = each.value.allocated_storage
  max_allocated_storage = each.value.max_storage
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.this["rds"].arn

  multi_az               = var.rds_multi_az
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds[each.key].id]
  publicly_accessible    = false

  backup_retention_period         = var.db_backup_retention_days
  backup_window                   = "17:00-18:00" # UTC (01:00-02:00 SGT)
  maintenance_window              = "sun:18:30-sun:19:30"
  copy_tags_to_snapshot           = true
  auto_minor_version_upgrade      = true
  enabled_cloudwatch_logs_exports = local.db_log_exports[each.value.engine]

  deletion_protection       = local.is_prod
  skip_final_snapshot       = !local.is_prod
  final_snapshot_identifier = local.is_prod ? "${local.name_prefix}-${each.key}-final" : null
  apply_immediately         = !local.is_prod

  tags = { Name = "${local.name_prefix}-${each.key}" }
}