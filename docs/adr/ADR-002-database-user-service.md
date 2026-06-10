# ADR-002: Database Technology for User Service

**Date:** 2025-01-15
**Status:** Accepted
**Deciders:** CloudMart Platform Team

---

## Context

The `user-service` (Python/Flask) is responsible for:
- User registration and login (bcrypt-hashed passwords)
- JWT token issuance
- Profile management (name, email, address)

We need a managed data store on AWS that supports:
- Relational queries (find by email, find by ID)
- Strong consistency for authentication (can't serve stale credentials)
- Encryption at rest and in transit
- Automated backups and point-in-time restore for DR
- Low cost for a student project

The assignment mandates use of **Amazon RDS for PostgreSQL** specifically.

## Considered Options

| Option | Type | AWS Service | Cost (student) | Notes |
|--------|------|-------------|---------------|-------|
| **Amazon RDS for PostgreSQL** | Managed RDBMS | RDS | **~$13/month (db.t3.micro)** | **Assignment requirement; well-suited for user data** |
| Amazon DynamoDB | Managed NoSQL | DynamoDB | ~$0 at low volume | Schema-less; poor fit for relational auth queries; no joins |
| Amazon Aurora Serverless v2 | Serverless RDBMS | Aurora | ~$0.12/ACU-hr; ~$40+ min | Higher cold-start latency; overkill for demo |
| Self-managed PostgreSQL on EC2 | RDBMS | EC2 | ~$5–10/month | No managed backups; operational overhead; not production-grade |

## Decision

**Use Amazon RDS for PostgreSQL 15 on db.t3.micro (Single-AZ for staging, Multi-AZ for prod).**

Rationale:
1. **Assignment requirement** — the brief explicitly requires Amazon RDS for PostgreSQL for the user-service
2. **Schema fitness** — user authentication data is inherently relational: unique email constraint, role-based access, profile fields with well-defined types
3. **Security** — RDS supports encryption at rest (KMS CMK), SSL in transit, and integration with Secrets Manager for credential rotation
4. **DR** — automated backups with 7-day retention and point-in-time restore satisfy the assignment's DR requirements
5. **Cost** — db.t3.micro at ~$13/month is the cheapest RDS option that supports a real workload

## Consequences

**Positive:**
- Fully managed: patches, backups, failover handled by AWS
- Point-in-time restore for DR (RPO ≤ 5 minutes)
- Multi-AZ for prod provides RTO ≈ 60–120 seconds on instance failure
- Credentials stored in Secrets Manager and injected via External Secrets Operator — no hardcoded secrets

**Negative:**
- Minimum ~$13/month even with zero traffic (unlike DynamoDB PAY_PER_REQUEST)
- db.t3.micro allows only ~80 connections max — acceptable for a demo; must move to db.t3.small+ for real production
- RDS runs in private data subnets; EKS nodes must route through security groups

## Implementation Notes

- Terraform resource: `infra/modules/rds/main.tf` — `aws_db_instance` with `engine = "postgres"`, `engine_version = "15"`
- Credentials stored as: `cloudmart/rds/user-service/<env>` in Secrets Manager
- `user-service` reads `DATABASE_URL` from env (injected by External Secrets Operator)
- Staging: `multi_az = false` | Prod: `multi_az = true`
- `deletion_protection = true` in prod
