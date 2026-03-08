#!/usr/bin/env bash
# =============================================================================
# GCP Infrastructure Audit Script
# Usage:   ./gcp-audit.sh [PROJECT_ID] [REGION]
# Example: ./gcp-audit.sh my-project europe-west4
# Output:  ./gcp-audit-<PROJECT_ID>-<timestamp>.txt
# =============================================================================

set -euo pipefail

PROJECT_ID="${1:-${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}}"
REGION="${2:-${REGION:-europe-west4}}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
OUTPUT_FILE="./gcp-audit-${PROJECT_ID}-${TIMESTAMP}.txt"

# Colours
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }

if [ -z "$PROJECT_ID" ]; then
  echo "ERROR: No PROJECT_ID supplied and no default gcloud project set."
  echo "Usage: ./gcp-audit.sh <PROJECT_ID> [REGION]"
  exit 1
fi

info "Auditing project : $PROJECT_ID"
info "Primary region   : $REGION"
info "Output file      : $OUTPUT_FILE"
echo ""

run() {
  # run <description> <command...>
  local desc="$1"; shift
  echo ""
  echo "=== ${desc} ==="
  "$@" 2>/dev/null || warn "Command failed or returned no results: $*"
}

{
echo "============================================================"
echo "GCP Audit  |  Project: $PROJECT_ID  |  $(date -Iseconds)"
echo "Primary region: $REGION"
echo "============================================================"

# ── 1. Project ────────────────────────────────────────────────
run "1. Active project" \
  gcloud config get-value project

run "1b. All projects" \
  gcloud projects list --format="table(projectId,name,lifecycleState)"

# ── 2. APIs ───────────────────────────────────────────────────
run "2. Enabled APIs" \
  gcloud services list --project="$PROJECT_ID" --enabled --format="table(config.name)"

# ── 3. Artifact Registry ──────────────────────────────────────
run "3. Artifact Registry repositories ($REGION)" \
  gcloud artifacts repositories list --project="$PROJECT_ID" --location="$REGION" --format="table(name,format,mode)"

echo ""
echo "=== 3b. Artifact Registry – detailed settings per repo ==="
for repo in $(gcloud artifacts repositories list --project="$PROJECT_ID" --location="$REGION" --format="value(name)" 2>/dev/null); do
  echo "--- Repository: $repo ---"
  gcloud artifacts repositories describe "$repo" --location="$REGION" --project="$PROJECT_ID" --format="yaml" 2>/dev/null || true
done

# ── 4. GCS Buckets ────────────────────────────────────────────
run "4. GCS buckets" \
  gcloud storage buckets list --project="$PROJECT_ID" --format="table(name,location,storageClass)"

# ── 5. Cloud Run ──────────────────────────────────────────────
run "5. Cloud Run services ($REGION)" \
  gcloud run services list --project="$PROJECT_ID" --region="$REGION" --format="table(metadata.name,status.url,status.conditions[0].status)"

echo ""
echo "=== 5b. Cloud Run – detailed specs per service ==="
for svc in $(gcloud run services list --project="$PROJECT_ID" --region="$REGION" --format="value(metadata.name)" 2>/dev/null); do
  echo "--- Service: $svc ---"
  gcloud run services describe "$svc" --region="$REGION" --project="$PROJECT_ID" \
    --format="yaml(spec.template.spec.containers,spec.template.spec.containerConcurrency,spec.template.metadata.annotations)" 2>/dev/null || true
done

run "5c. Cloud Run jobs ($REGION)" \
  gcloud run jobs list --project="$PROJECT_ID" --region="$REGION" --format="table(metadata.name,status.conditions[0].type)"

echo ""
echo "=== 5d. Cloud Run jobs – detailed specs ==="
for job in $(gcloud run jobs list --project="$PROJECT_ID" --region="$REGION" --format="value(metadata.name)" 2>/dev/null); do
  echo "--- Job: $job ---"
  gcloud run jobs describe "$job" --region="$REGION" --project="$PROJECT_ID" --format="yaml" 2>/dev/null || true
done

# ── 6. Cloud Scheduler ────────────────────────────────────────
echo ""
echo "=== 6. Cloud Scheduler – scanning all regions ==="
SCHEDULER_REGIONS=(europe-west1 europe-west2 europe-west3 europe-west4 europe-north1 us-central1 us-east1 us-east4 us-west1 asia-east1 asia-southeast1)
for r in "${SCHEDULER_REGIONS[@]}"; do
  count=$(gcloud scheduler jobs list --project="$PROJECT_ID" --location="$r" --format="value(name)" 2>/dev/null | wc -l)
  if [ "$count" -gt 0 ]; then
    echo "--- Region: $r ($count jobs) ---"
    gcloud scheduler jobs list --project="$PROJECT_ID" --location="$r" \
      --format="table(name,schedule,state,timeZone)" 2>/dev/null || true
    echo ""
    gcloud scheduler jobs list --project="$PROJECT_ID" --location="$r" \
      --format="yaml(name,schedule,timeZone,state,httpTarget.uri)" 2>/dev/null || true
  fi
done

# ── 7. Cloud SQL ──────────────────────────────────────────────
run "7. Cloud SQL instances" \
  gcloud sql instances list --project="$PROJECT_ID" --format="table(name,region,databaseVersion,state)"

echo ""
echo "=== 7b. Cloud SQL – databases per instance ==="
for inst in $(gcloud sql instances list --project="$PROJECT_ID" --format="value(name)" 2>/dev/null); do
  echo "--- Instance: $inst ---"
  gcloud sql databases list --project="$PROJECT_ID" --instance="$inst" --format="table(name)" 2>/dev/null || true
done

echo ""
echo "=== 7c. Cloud SQL – full specs per instance ==="
for inst in $(gcloud sql instances list --project="$PROJECT_ID" --format="value(name)" 2>/dev/null); do
  echo "--- Instance: $inst ---"
  gcloud sql instances describe "$inst" --project="$PROJECT_ID" \
    --format="yaml(settings.tier,settings.dataDiskSizeGb,settings.dataDiskType,settings.backupConfiguration,settings.ipConfiguration,settings.maintenanceWindow,settings.databaseFlags)" 2>/dev/null || true
done

# ── 8. VPC & Networking ───────────────────────────────────────
run "8. VPC networks" \
  gcloud compute networks list --project="$PROJECT_ID" --format="table(name,mode,routingConfig.routingMode)"

run "8b. Subnets" \
  gcloud compute networks subnets list --project="$PROJECT_ID" --format="table(name,region,ipCidrRange,network)"

run "8c. VPC connectors ($REGION)" \
  gcloud compute networks vpc-access connectors list --project="$PROJECT_ID" --region="$REGION" \
    --format="table(name,network,ipCidrRange,state,minInstances,maxInstances,machineType)"

echo ""
echo "=== 8d. VPC connectors – detailed specs ==="
for conn in $(gcloud compute networks vpc-access connectors list --project="$PROJECT_ID" --region="$REGION" --format="value(name)" 2>/dev/null); do
  echo "--- Connector: $conn ---"
  gcloud compute networks vpc-access connectors describe "$conn" --region="$REGION" --project="$PROJECT_ID" --format="yaml" 2>/dev/null || true
done

run "8e. Cloud Routers" \
  gcloud compute routers list --project="$PROJECT_ID" --format="table(name,region,network)"

echo ""
echo "=== 8f. Cloud Routers – detailed config (NAT etc.) ==="
gcloud compute routers list --project="$PROJECT_ID" --format="value(name,region)" 2>/dev/null | \
while IFS=$'\t' read -r name region; do
  [ -z "$name" ] && continue
  echo "--- Router: $name (region: $region) ---"
  gcloud compute routers describe "$name" --region="$region" --project="$PROJECT_ID" --format="yaml" 2>/dev/null || true
done

run "8g. Firewall rules" \
  gcloud compute firewall-rules list --project="$PROJECT_ID" --format="table(name,network,direction,priority,disabled)"

echo ""
echo "=== 8h. Firewall rules – detailed (sourceRanges, targetTags, allowed) ==="
gcloud compute firewall-rules list --project="$PROJECT_ID" \
  --format="yaml(name,direction,priority,sourceRanges,destinationRanges,targetTags,targetServiceAccounts,allowed,denied,disabled)" 2>/dev/null || true

run "8i. Static external IPs" \
  gcloud compute addresses list --project="$PROJECT_ID" --format="table(name,address,region,status,addressType)"

run "8j. Load balancers – forwarding rules" \
  gcloud compute forwarding-rules list --project="$PROJECT_ID" --format="table(name,region,IPAddress,target,loadBalancingScheme)"

run "8k. Cloud DNS managed zones" \
  gcloud dns managed-zones list --project="$PROJECT_ID" --format="table(name,dnsName,visibility)"

# ── 9. Compute Engine ─────────────────────────────────────────
run "9. Compute Engine VMs" \
  gcloud compute instances list --project="$PROJECT_ID" --format="table(name,zone,status,machineType,tags.items[].list())"

echo ""
echo "=== 9b. Compute Engine disks ==="
gcloud compute disks list --project="$PROJECT_ID" \
  --format="yaml(name,sizeGb,type,zone,sourceImage,status)" 2>/dev/null || true

run "9c. Instance groups" \
  gcloud compute instance-groups list --project="$PROJECT_ID" --format="table(name,zone,size)"

# ── 10. GKE ───────────────────────────────────────────────────
run "10. GKE clusters" \
  gcloud container clusters list --project="$PROJECT_ID" --format="table(name,location,status,currentMasterVersion,currentNodeCount)"

echo ""
echo "=== 10b. GKE clusters – detailed specs ==="
for cluster in $(gcloud container clusters list --project="$PROJECT_ID" --format="value(name,location)" 2>/dev/null | awk '{print $1"/"$2}'); do
  name="${cluster%%/*}"; location="${cluster##*/}"
  echo "--- Cluster: $name ($location) ---"
  gcloud container clusters describe "$name" --location="$location" --project="$PROJECT_ID" \
    --format="yaml(nodeConfig,nodePools,autoscaling,masterAuthorizedNetworksConfig,networkConfig)" 2>/dev/null || true
done

# ── 11. Cloud Functions ───────────────────────────────────────
run "11. Cloud Functions (gen1 + gen2)" \
  gcloud functions list --project="$PROJECT_ID" --format="table(name,region,status,runtime,trigger)"

# ── 12. Redis / Memorystore ───────────────────────────────────
run "12. Redis instances (Memorystore)" \
  gcloud redis instances list --project="$PROJECT_ID" --region="$REGION" \
    --format="table(name,region,tier,memorySizeGb,state)" 2>/dev/null || \
  gcloud redis instances list --project="$PROJECT_ID" \
    --format="table(name,region,tier,memorySizeGb,state)" 2>/dev/null || true

# ── 13. Pub/Sub ───────────────────────────────────────────────
run "13. Pub/Sub topics" \
  gcloud pubsub topics list --project="$PROJECT_ID" --format="table(name)"

run "13b. Pub/Sub subscriptions" \
  gcloud pubsub subscriptions list --project="$PROJECT_ID" \
    --format="table(name,topic,ackDeadlineSeconds,messageRetentionDuration)"

# ── 14. Secret Manager ────────────────────────────────────────
run "14. Secrets" \
  gcloud secrets list --project="$PROJECT_ID" --format="yaml(name,replication,labels)"

# ── 15. IAM ───────────────────────────────────────────────────
run "15. IAM project policy" \
  gcloud projects get-iam-policy "$PROJECT_ID" --format="yaml"

run "15b. Service accounts" \
  gcloud iam service-accounts list --project="$PROJECT_ID" --format="table(email,displayName,disabled)"

echo ""
echo "=== 15c. Service account keys (check for old keys) ==="
for sa in $(gcloud iam service-accounts list --project="$PROJECT_ID" --format="value(email)" 2>/dev/null); do
  keys=$(gcloud iam service-accounts keys list --iam-account="$sa" --project="$PROJECT_ID" \
    --format="table(name,validAfterTime,validBeforeTime,keyType)" 2>/dev/null | grep -v "^NAME" || true)
  if [ -n "$keys" ]; then
    echo "--- $sa ---"
    echo "$keys"
  fi
done

# ── 16. Cloud Build ───────────────────────────────────────────
run "16. Cloud Build triggers" \
  gcloud builds triggers list --project="$PROJECT_ID" --format="yaml"

# ── 17. Logging ───────────────────────────────────────────────
run "17. Logging sinks" \
  gcloud logging sinks list --project="$PROJECT_ID"

run "17b. Log-based metrics" \
  gcloud logging metrics list --project="$PROJECT_ID" --format="table(name,description)"

# ── 18. Monitoring ────────────────────────────────────────────
run "18. Monitoring alert policies" \
  gcloud alpha monitoring policies list --project="$PROJECT_ID" --format="yaml"

run "18b. Monitoring notification channels" \
  gcloud monitoring channels list --project="$PROJECT_ID" --format="yaml"

run "18c. Monitoring uptime checks" \
  gcloud monitoring uptime list-configs --project="$PROJECT_ID" --format="yaml"

run "18d. Monitoring dashboards" \
  gcloud monitoring dashboards list --project="$PROJECT_ID" --format="yaml"

run "18e. Monitoring services (for SLOs)" \
  gcloud monitoring services list --project="$PROJECT_ID" --format="yaml"

echo ""
echo "=== 18f. SLOs per monitoring service ==="
for svc in $(gcloud monitoring services list --project="$PROJECT_ID" --format="value(name)" 2>/dev/null); do
  [ -z "$svc" ] && continue
  echo "--- Service: $svc ---"
  gcloud monitoring slos list --project="$PROJECT_ID" --service="$svc" --format="yaml" 2>/dev/null || true
done

# ── 19. Cloud Endpoints / API Gateway ────────────────────────
run "19. Cloud Endpoints services" \
  gcloud endpoints services list --project="$PROJECT_ID" --format="table(serviceName,title)"

# ── 20. Summary ───────────────────────────────────────────────
echo ""
echo "============================================================"
echo "End of audit  |  $(date -Iseconds)"
echo "Project: $PROJECT_ID  |  Region: $REGION"
echo "Output: $OUTPUT_FILE"
echo "============================================================"

} | tee "$OUTPUT_FILE"

echo ""
info "Done. Full output written to: $OUTPUT_FILE"
