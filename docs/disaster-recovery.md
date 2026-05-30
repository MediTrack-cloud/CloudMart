# CloudMart Disaster Recovery Plan

## 1. RTO / RPO Targets

| Tier | Component | RPO | RTO | Mechanism |
|------|-----------|-----|-----|-----------|
| Critical | RDS PostgreSQL (prod) | ≤ 5 min | ≤ 2 min | Multi-AZ automatic failover |
| Critical | EKS workloads | ≤ 24 hrs | ≤ 30 min | Velero restore from S3 |
| Standard | DynamoDB products | ≤ 5 min | ≤ 5 min | Point-in-time recovery |
| Standard | Infrastructure | ≤ 0 (IaC) | ≤ 60 min | Terraform re-apply |
| Low | SQS queue | ≤ 0 | N/A | AWS-managed HA |
| Low | DNS failover | ≤ 30 sec | ≤ 30 sec | Route 53 health-check + S3 |

**Business justification:**
- 2-minute RTO for RDS: user registration and checkout depend on PostgreSQL; longer downtime directly impacts revenue.
- 30-minute RTO for K8s workloads: acceptable for a startup; Velero restores the full namespace including secrets and configmaps.

---

## 2. Backup Strategy

### 2.1 RDS PostgreSQL

- **Automated backups:** enabled, 7-day retention window
- **Point-in-time restore:** available to any second within the retention window
- **Snapshot before major changes:** `aws rds create-db-snapshot --db-instance-identifier cloudmart-prod`
- **Multi-AZ (prod):** synchronous replication to standby in us-east-1b; failover < 2 min

### 2.2 DynamoDB Products Table

- **Point-in-time recovery:** enabled (up to 35-day window)
- **On-demand backup:** `aws dynamodb create-backup --table-name cloudmart-products-prod`

### 2.3 Kubernetes Resources (Velero)

- **Schedule:** daily at 02:00 UTC (`0 2 * * *`)
- **Retention:** 7 days
- **Storage:** S3 bucket `cloudmart-velero-<account-id>` (versioned, KMS-encrypted)
- **Scope:** `cloudmart-prod` namespace (Deployments, Services, Ingress, ConfigMaps, Secrets)
- **Restore procedure:** see `k8s/velero/RESTORE-PROCEDURE.md`

### 2.4 Terraform Infrastructure

- All infrastructure is defined as Terraform code in `infra/`
- Remote state in S3 (versioned) with DynamoDB state locking
- Full stack can be rebuilt in ~60 minutes with `terraform apply`

---

## 3. DNS Failover

Route 53 monitors the ALB health check endpoint (`HTTPS /health`). If 3 consecutive checks fail (90-second window), traffic is automatically routed to the S3 static maintenance page (`infra/modules/s3/main.tf`).

The S3 page displays:

> "CloudMart is currently undergoing scheduled maintenance. We apologise for the inconvenience and expect to be back online shortly."

To demonstrate:
```bash
# Simulate ALB outage by temporarily blocking health check (demo only)
aws route53 get-health-check --health-check-id <id>
# Traffic automatically reroutes to S3 within 90 seconds of health-check failure
```

---

## 4. Recovery Runbook

### 4.1 Database Failover (RDS Multi-AZ)

```bash
# Failover is automatic in prod — no manual action required
# To manually force failover (for testing):
aws rds reboot-db-instance \
  --db-instance-identifier cloudmart-prod \
  --force-failover

# Verify endpoint after failover (DNS updates automatically):
aws rds describe-db-instances \
  --db-instance-identifier cloudmart-prod \
  --query 'DBInstances[0].Endpoint.Address'
```

### 4.2 Point-in-Time RDS Restore (to test instance)

```bash
# Restore to 2 hours ago into a test instance
aws rds restore-db-instance-to-point-in-time \
  --source-db-instance-identifier cloudmart-prod \
  --target-db-instance-identifier cloudmart-prod-restore-test \
  --restore-time $(date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%SZ)

# Wait for the instance to become available (~10 min)
aws rds wait db-instance-available \
  --db-instance-identifier cloudmart-prod-restore-test

# Connect and verify data
psql -h <restore-endpoint> -U cloudmart -d cloudmart
```

### 4.3 Kubernetes Namespace Restore (Velero)

```bash
# List available backups
velero backup get

# Restore production namespace
velero restore create cloudmart-restore \
  --from-backup cloudmart-prod-daily-<date> \
  --include-namespaces cloudmart-prod \
  --wait

# Verify
kubectl get pods -n cloudmart-prod
```

### 4.4 Full Infrastructure Rebuild

```bash
# Re-provision all AWS resources
cd infra/environments/prod
terraform init -backend-config=backend.tf
terraform apply -auto-approve

# Re-apply Kubernetes manifests
kubectl apply -k k8s/overlays/prod

# Restore from latest Velero backup
velero restore create --from-backup $(velero backup get | tail -1 | awk '{print $1}') --wait
```

---

## 5. Test Evidence

For the live demo, show:

1. RDS automated backup enabled (AWS Console → RDS → Maintenance & backups)
2. PITR restore to a test instance (console or CLI — see §4.2)
3. Velero backup schedule: `kubectl get schedule -n velero`
4. Velero restore to test namespace: `k8s/velero/RESTORE-PROCEDURE.md §7`
5. Route 53 health check: AWS Console → Route 53 → Health Checks
