# CloudMart Kubernetes Restore Procedure (Velero)

## Prerequisites

- Velero CLI installed: `brew install velero` (or download from GitHub releases)
- `kubectl` configured for the target cluster
- AWS credentials with S3 read access to the Velero bucket

---

## 1. List Available Backups

```bash
velero backup get
# NAME                                STATUS     CREATED                         ...
# cloudmart-prod-daily-20260516020000 Completed  2026-05-16 02:00:00 +0000 UTC
```

---

## 2. Restore from a Specific Backup

```bash
# Full namespace restore
velero restore create --from-backup cloudmart-prod-daily-20260516020000 \
  --include-namespaces cloudmart-prod \
  --wait

# Check restore status
velero restore get
velero restore describe <restore-name>
```

---

## 3. Restore a Single Resource

```bash
velero restore create --from-backup cloudmart-prod-daily-20260516020000 \
  --include-namespaces cloudmart-prod \
  --include-resources deployments \
  --selector app=product-service
```

---

## 4. Verify Restored Resources

```bash
kubectl get pods -n cloudmart-prod
kubectl get deployments -n cloudmart-prod
kubectl get services -n cloudmart-prod
kubectl get ingress -n cloudmart-prod
```

---

## 5. On-Demand Backup (before risky changes)

```bash
velero backup create cloudmart-prod-manual-$(date +%Y%m%d%H%M) \
  --include-namespaces cloudmart-prod \
  --wait
```

---

## 6. RTO/RPO Evidence

| Target | Value | Mechanism |
|--------|-------|-----------|
| RPO    | ≤ 24 hours | Daily automated Velero backup at 02:00 UTC |
| RTO (K8s) | ≤ 30 minutes | Velero restore from S3 to new cluster |
| RTO (RDS) | ≤ 2 minutes (prod) | Multi-AZ automatic failover |
| RPO (RDS) | ≤ 5 minutes | Automated backups + binary log replication |

---

## 7. Test Restore (for Demo)

```bash
# Create a test namespace to verify restore works without affecting prod
velero restore create cloudmart-restore-test \
  --from-backup cloudmart-prod-daily-20260516020000 \
  --namespace-mappings cloudmart-prod:cloudmart-restore-test \
  --wait

kubectl get pods -n cloudmart-restore-test
# Verify pods start successfully, then clean up:
kubectl delete namespace cloudmart-restore-test
```
