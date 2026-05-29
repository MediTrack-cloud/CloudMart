# CloudMart — Production-Grade Microservices on AWS EKS

CloudMart is a production-grade e-commerce platform deployed as five microservices on Amazon EKS. This repository contains the complete infrastructure as code and Kubernetes manifests for the platform.

## Infrastructure Overview

The infrastructure is provisioned using Terraform and is organized into reusable modules.

### Core Modules

- **VPC**: A three-tier network design (public, private-app, private-data) across multiple availability zones. Includes NAT Gateways, VPC Endpoints (S3, DynamoDB, Secrets Manager, ECR), and VPC Flow Logs.
- **RDS**: Managed PostgreSQL database for the user-service with encryption at rest and automated backups.
- **DynamoDB**: Managed NoSQL database for the product catalogue.
- **SQS**: Message queues for order processing with dead-letter queue support.
- **KMS**: Customer Master Keys (CMKs) for encrypting sensitive data and database volumes.
- **S3**: Storage for Terraform state, Velero backups, and a static maintenance page.
- **Route 53**: DNS management with health-check based failover to a static DR site.

## Repository Structure

```
CloudMart/
├── infra/                  # Terraform infrastructure as code
│   ├── bootstrap/          # S3 state bucket + DynamoDB lock table
│   ├── environments/       # prod/ and staging/ environment configs
│   └── modules/            # Reusable modules (vpc, rds, dynamodb, etc.)
├── k8s/                    # Kubernetes manifests (base templates)
├── services/               # Microservice source code (starter)
└── docker-compose.yml      # Local development environment
```

## Getting Started

Refer to the documentation in each module and environment directory for specific configuration details.
