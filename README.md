# gcp-audit

A single shell script that produces a complete snapshot of a GCP project's infrastructure. Designed to be the first thing you run on any new or existing project — before writing Terraform, before migrating, before anything.

## What it audits

| # | Area |
|---|------|
| 1 | Projects |
| 2 | Enabled APIs |
| 3 | Artifact Registry (repos + cleanup policies) |
| 4 | GCS Buckets |
| 5 | Cloud Run (services + jobs, full specs) |
| 6 | Cloud Scheduler (all regions, timezones) |
| 7 | Cloud SQL (tier, disk, backup, SSL config) |
| 8 | Networking (VPC, subnets, connectors, routers, NAT, firewall, DNS, load balancers, static IPs) |
| 9 | Compute Engine (VMs, disks, instance groups) |
| 10 | GKE clusters |
| 11 | Cloud Functions (gen1 + gen2) |
| 12 | Redis / Memorystore |
| 13 | Pub/Sub (topics + subscriptions) |
| 14 | Secret Manager (names only, never values) |
| 15 | IAM (project policy, service accounts, key age) |
| 16 | Cloud Build triggers |
| 17 | Logging (sinks + log-based metrics) |
| 18 | Monitoring (alerts, notification channels, uptime checks, dashboards, SLOs) |
| 19 | Cloud Endpoints / API Gateway |

## Requirements

- `gcloud` CLI installed and authenticated
- Sufficient IAM permissions on the target project (viewer + monitoring viewer is enough for read-only audit)

```bash
gcloud auth login
gcloud auth application-default login
```

## Usage

```bash
# Audit with explicit project and region
./gcp-audit.sh my-project-id europe-west4

# Audit using environment variables
PROJECT_ID=my-project-id REGION=us-east1 ./gcp-audit.sh

# Audit using the currently active gcloud project
./gcp-audit.sh
```

Output is written to `./gcp-audit-<PROJECT_ID>-<timestamp>.txt` and printed to stdout simultaneously.

## Typical workflow

```
1. Clone this repo into the client project folder
2. Run ./gcp-audit.sh <project-id> <region>
3. Review the output file
4. Feed the output into Cursor/Claude to generate Terraform
5. Run terraform import for existing resources
```

## Using the output to generate Terraform

The audit output is structured to be used directly as context for AI-assisted Terraform generation. Paste the full output into Cursor or Claude with a prompt like:

```
This is a full GCP infrastructure audit for project [PROJECT_ID].
Write complete Terraform code that matches this existing infrastructure exactly.
Do not create anything new. Use modules for: apis, networking, database, cloudrun, scheduler, secrets.
Store state in a new GCS bucket called [project-id]-terraform-state in [region].
```

## Notes

- **Secrets are never exported** — Secret Manager names are listed but values are never read
- **Service account keys** are listed per SA so you can spot old or unused keys
- **Cloud Scheduler** scans all common regions automatically — jobs can exist in any region
- The script uses `|| true` throughout so a missing resource or permission never stops the full audit

## Repository structure

```
gcp-audit/
├── gcp-audit.sh      # The audit script
└── README.md         # This file
```
