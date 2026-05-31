# GuardDuty Finding — Response Action

**Finding (sample, generated for the demo):** `Recon:EC2/PortProbeUnprotectedPort` /
`UnauthorizedAccess:EC2/SSHBruteForce` on detector `16cf3e91f8149e899bdbf8034d538e27` (us-east-1).

GuardDuty is enabled on the account with EKS audit logs, S3 protection and malware scanning.
HIGH/CRITICAL findings (severity ≥ 7) route **EventBridge → SNS → email** for on-call triage.

## Response runbook (what we do when a finding fires)

1. **Triage** — open the finding in *GuardDuty → Findings*; confirm severity, the affected
   resource (instance/EKS pod), and the offending source IP.
2. **Contain** —
   - Network: add the source IP to the **WAF IP-block set** on the ALB and tighten the relevant
     **Security Group** / **NetworkPolicy** so the implicated workload can't talk out.
   - Identity: if a pod/role is implicated, revoke the session — the per-service **IRSA** role is
     scoped to one resource, so blast radius is already minimal; rotate the role if needed.
3. **Eradicate** — for a compromised node, cordon + drain and let the **Cluster Autoscaler**
   replace it (IMDSv2 is enforced, so node credentials can't be harvested from a pod).
4. **Recover** — confirm replacement workloads healthy; for data concerns restore from the
   automated RDS backup / Velero namespace backup.
5. **Review** — record the timeline; if it was a true positive, add a detection/alert and (if
   relevant) a Kyverno policy to prevent recurrence.

**Evidence:** see `EV-SEC-03-guardduty-finding.txt` (CLI list of active findings) and the console
screenshot `EV-SEC-03-guardduty-finding.png` (GuardDuty → Findings).
