#!/usr/bin/env bash
# =============================================================================
# GCP Infrastructure Audit Script
# Usage:   ./gcp-audit.sh [PROJECT_ID] [REGION]
# Example: ./gcp-audit.sh my-project europe-west4
# Output:  ./gcp-audit-<PROJECT_ID>-<timestamp>.txt
# =============================================================================

set -euo pipefail

PROJECT_ID="${1:-${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}}"
REGION="${2:-${REGION:-}}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
OUTPUT_FILE="./gcp-audit-${PROJECT_ID}-${TIMESTAMP}.txt"

# Colours
GREEN='\e[0;32m'; YELLOW='\e[1;33m'; RED='\e[0;31m'; NC='\e[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERR]${NC}   $*"; }

if [ -z "$PROJECT_ID" ]; then
  err "No PROJECT_ID supplied and no default gcloud project set."
  echo "Usage: ./gcp-audit.sh <PROJECT_ID> <REGION>"
  echo "Example: ./gcp-audit.sh my-project europe-west4"
  exit 1
fi

if [ -z "$REGION" ]; then
  err "No REGION supplied."
  echo "Usage: ./gcp-audit.sh <PROJECT_ID> <REGION>"
  echo "Example: ./gcp-audit.sh my-project europe-west4"
  exit 1
fi

info "Auditing project : $PROJECT_ID"
info "Primary region   : $REGION"
info "Output file      : $OUTPUT_FILE"
echo ""

# Helper: print section header, run command, warn on failure
run() {
  local desc="$1"; shift
  echo ""
  echo "=== ${desc} ==="
  "$@" 2>/dev/null || warn "No results or insufficient permissions: $*"
}

# Helper: check if a section returned anything meaningful
check_empty() {
  local section="$1"
  local output="$2"
  if [ -z "$(echo "$output" | grep -v '^$')" ]; then
    echo "(none found)"
  else
    echo "$output"
  fi
}

{
echo "============================================================"
echo "GCP Audit  |  Project: $PROJECT_ID  |  $(date -Iseconds)"
echo "Primary region: $REGION"
echo "============================================================"
echo ""
echo "TABLE OF CONTENTS"
echo "  1.  Projects"
echo "  2.  Enabled APIs"
echo "  3.  Artifact Registry"
echo "  4.  GCS Buckets"
echo "  5.  Cloud Run (services, IAM, jobs)"
echo "  6.  Cloud Scheduler"
echo "  7.  Cloud SQL"
echo "  8.  VPC & Networking (connectors, routers, firewall, DNS)"
echo "  9.  Compute Engine"
echo "  10. GKE"
echo "  11. Cloud Functions"
echo "  12. Redis / Memorystore"
echo "  13. Pub/Sub"
echo "  14. Secret Manager"
echo "  15. IAM (policy, service accounts, keys)"
echo "  16. Cloud Build"
echo "  17. Logging"
echo "  18. Monitoring (alerts, channels, uptime, SLOs)"
echo "  19. Cloud Endpoints"
echo "  [WARN] Security summary — grep '\[WARN\]' to filter"
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
  gcloud artifacts repositories list \
    --project="$PROJECT_ID" --location="$REGION" \
    --format="table(name,format,mode,description)"

echo ""
echo "=== 3b. Artifact Registry – detailed settings per repo ==="
for repo in $(gcloud artifacts repositories list \
    --project="$PROJECT_ID" --location="$REGION" \
    --format="value(name)" 2>/dev/null); do
  echo "--- Repository: $repo ---"
  gcloud artifacts repositories describe "$repo" \
    --location="$REGION" --project="$PROJECT_ID" \
    --format="yaml" 2>/dev/null || warn "Could not describe repo: $repo"
done

# ── 4. GCS Buckets ────────────────────────────────────────────
run "4. GCS buckets" \
  gcloud storage buckets list \
    --project="$PROJECT_ID" \
    --format="table(name,location,storageClass,iamConfiguration.publicAccessPrevention)"

echo ""
echo "=== 4b. GCS buckets – flag buckets outside primary region ==="
gcloud storage buckets list --project="$PROJECT_ID" \
  --format="value(name,location)" 2>/dev/null | \
while IFS=$'\t' read -r name loc; do
  loc_upper=$(echo "$loc" | tr '[:lower:]' '[:upper:]')
  region_upper=$(echo "$REGION" | tr '[:lower:]' '[:upper:]')
  if [[ "$loc_upper" != *"$region_upper"* ]]; then
    warn "BUCKET OUT OF REGION: $name is in $loc (expected $REGION)"
  fi
done

# ── 5. Cloud Run ──────────────────────────────────────────────
run "5. Cloud Run services ($REGION)" \
  gcloud run services list \
    --project="$PROJECT_ID" --region="$REGION" \
    --format="table(metadata.name,status.url,status.conditions[0].status)"

echo ""
echo "=== 5b. Cloud Run – detailed specs per service ==="
for svc in $(gcloud run services list \
    --project="$PROJECT_ID" --region="$REGION" \
    --format="value(metadata.name)" 2>/dev/null); do
  echo "--- Service: $svc ---"
  gcloud run services describe "$svc" \
    --region="$REGION" --project="$PROJECT_ID" \
    --format="yaml(spec.template.spec.containers,spec.template.spec.containerConcurrency,spec.template.metadata.annotations)" \
    2>/dev/null || warn "Could not describe service: $svc"
done

echo ""
echo "=== 5b-iam. Cloud Run – IAM policies per service ==="
for svc in $(gcloud run services list \
    --project="$PROJECT_ID" --region="$REGION" \
    --format="value(metadata.name)" 2>/dev/null); do
  echo "--- IAM policy: $svc ---"
  policy=$(gcloud run services get-iam-policy "$svc" \
    --region="$REGION" --project="$PROJECT_ID" \
    --format="yaml" 2>/dev/null || true)
  echo "$policy"
  # Flag public access
  if echo "$policy" | grep -q "allUsers\|allAuthenticatedUsers"; then
    warn "PUBLIC ACCESS: $svc is publicly invokable (allUsers or allAuthenticatedUsers)"
  fi
done

run "5c. Cloud Run jobs ($REGION)" \
  gcloud run jobs list \
    --project="$PROJECT_ID" --region="$REGION" \
    --format="table(metadata.name,status.conditions[0].type,status.executionCount)"

echo ""
echo "=== 5d. Cloud Run jobs – detailed specs ==="
for job in $(gcloud run jobs list \
    --project="$PROJECT_ID" --region="$REGION" \
    --format="value(metadata.name)" 2>/dev/null); do
  echo "--- Job: $job ---"
  gcloud run jobs describe "$job" \
    --region="$REGION" --project="$PROJECT_ID" \
    --format="yaml" 2>/dev/null || warn "Could not describe job: $job"
done

# ── 6. Cloud Scheduler ────────────────────────────────────────
echo ""
echo "=== 6. Cloud Scheduler – scanning all regions ==="
SCHEDULER_REGIONS=(
  europe-west1 europe-west2 europe-west3 europe-west4 europe-west6
  europe-north1 europe-central2
  us-central1 us-east1 us-east4 us-west1 us-west2
  asia-east1 asia-southeast1 asia-northeast1
)
for r in "${SCHEDULER_REGIONS[@]}"; do
  jobs=$(gcloud scheduler jobs list \
    --project="$PROJECT_ID" --location="$r" \
    --format="value(name)" 2>/dev/null)
  count=$(echo "$jobs" | grep -c . || true)
  if [ "$count" -gt 0 ]; then
    echo "--- Region: $r ($count jobs) ---"
    gcloud scheduler jobs list \
      --project="$PROJECT_ID" --location="$r" \
      --format="table(name,schedule,state,timeZone)" 2>/dev/null || true
    echo ""
    gcloud scheduler jobs list \
      --project="$PROJECT_ID" --location="$r" \
      --format="yaml(name,schedule,timeZone,state,httpTarget.uri,httpTarget.oidcToken)" \
      2>/dev/null || true
  fi
done

# ── 7. Cloud SQL ──────────────────────────────────────────────
run "7. Cloud SQL instances" \
  gcloud sql instances list \
    --project="$PROJECT_ID" \
    --format="table(name,region,databaseVersion,state,settings.tier)"

echo ""
echo "=== 7b. Cloud SQL – databases per instance ==="
for inst in $(gcloud sql instances list \
    --project="$PROJECT_ID" --format="value(name)" 2>/dev/null); do
  echo "--- Instance: $inst ---"
  gcloud sql databases list \
    --project="$PROJECT_ID" --instance="$inst" \
    --format="table(name,charset,collation)" 2>/dev/null || true
done

echo ""
echo "=== 7c. Cloud SQL – full specs per instance ==="
for inst in $(gcloud sql instances list \
    --project="$PROJECT_ID" --format="value(name)" 2>/dev/null); do
  echo "--- Instance: $inst ---"
  gcloud sql instances describe "$inst" --project="$PROJECT_ID" \
    --format="yaml(settings.tier,settings.dataDiskSizeGb,settings.dataDiskType,settings.backupConfiguration,settings.ipConfiguration,settings.maintenanceWindow,settings.databaseFlags,settings.insightsConfig)" \
    2>/dev/null || true

  echo ""
  echo "  [IP check]"
  public_ip=$(gcloud sql instances describe "$inst" --project="$PROJECT_ID" \
    --format="value(settings.ipConfiguration.ipv4Enabled)" 2>/dev/null)
  if [ "$public_ip" = "True" ]; then
    warn "SECURITY: $inst has a PUBLIC IP enabled!"
  else
    echo "  OK: $inst has no public IP"
  fi
done

# ── 8. VPC & Networking ───────────────────────────────────────
run "8. VPC networks" \
  gcloud compute networks list \
    --project="$PROJECT_ID" \
    --format="table(name,mode,routingConfig.routingMode,autoCreateSubnetworks)"

run "8b. Subnets" \
  gcloud compute networks subnets list \
    --project="$PROJECT_ID" \
    --format="table(name,region,ipCidrRange,network,privateIpGoogleAccess)"

run "8c. VPC connectors ($REGION)" \
  gcloud compute networks vpc-access connectors list \
    --project="$PROJECT_ID" --region="$REGION" \
    --format="table(name,network,ipCidrRange,state,minInstances,maxInstances,machineType)"

echo ""
echo "=== 8d. VPC connectors – detailed specs ==="
for conn in $(gcloud compute networks vpc-access connectors list \
    --project="$PROJECT_ID" --region="$REGION" \
    --format="value(name)" 2>/dev/null); do
  echo "--- Connector: $conn ---"
  gcloud compute networks vpc-access connectors describe "$conn" \
    --region="$REGION" --project="$PROJECT_ID" \
    --format="yaml" 2>/dev/null || true
done

run "8e. Cloud Routers" \
  gcloud compute routers list \
    --project="$PROJECT_ID" \
    --format="table(name,region,network)"

echo ""
echo "=== 8f. Cloud Routers – detailed config (NAT etc.) ==="
gcloud compute routers list \
  --project="$PROJECT_ID" \
  --format="value(name,region)" 2>/dev/null | \
while IFS=$'\t' read -r name region; do
  [ -z "$name" ] && continue
  echo "--- Router: $name (region: $region) ---"
  gcloud compute routers describe "$name" \
    --region="$region" --project="$PROJECT_ID" \
    --format="yaml" 2>/dev/null || true
done

echo ""
echo "=== 8g. Firewall rules – table ==="
gcloud compute firewall-rules list \
  --project="$PROJECT_ID" \
  --format="table(name,network,direction,priority,disabled)" 2>/dev/null || true

echo ""
echo "=== 8h. Firewall rules – detailed + security flags ==="
gcloud compute firewall-rules list \
  --project="$PROJECT_ID" \
  --format="yaml(name,direction,priority,sourceRanges,destinationRanges,targetTags,targetServiceAccounts,allowed,denied,disabled)" \
  2>/dev/null || true

echo ""
echo "=== 8h-sec. Firewall security checks ==="
# Check for dangerous open rules
gcloud compute firewall-rules list \
  --project="$PROJECT_ID" \
  --format="value(name,sourceRanges.list(),allowed[].map().firewall_key().list())" \
  2>/dev/null | \
while IFS=$'\t' read -r name ranges allowed; do
  if echo "$ranges" | grep -q "0.0.0.0/0"; then
    if echo "$allowed" | grep -qE "tcp:22|tcp:3389|tcp:3306|tcp:5432|tcp:27017"; then
      warn "SECURITY RISK: $name is open to 0.0.0.0/0 on sensitive port: $allowed"
    fi
  fi
done

run "8i. Static external IPs" \
  gcloud compute addresses list \
    --project="$PROJECT_ID" \
    --format="table(name,address,region,status,addressType)"

run "8j. Load balancers – forwarding rules" \
  gcloud compute forwarding-rules list \
    --project="$PROJECT_ID" \
    --format="table(name,region,IPAddress,target,loadBalancingScheme)"

run "8k. Cloud DNS managed zones" \
  gcloud dns managed-zones list \
    --project="$PROJECT_ID" \
    --format="table(name,dnsName,visibility)"

echo ""
echo "=== 8l. Cloud DNS – records per zone ==="
for zone in $(gcloud dns managed-zones list \
    --project="$PROJECT_ID" --format="value(name)" 2>/dev/null); do
  echo "--- Zone: $zone ---"
  gcloud dns record-sets list \
    --zone="$zone" --project="$PROJECT_ID" \
    --format="table(name,type,ttl,rrdatas)" 2>/dev/null || true
done

# ── 9. Compute Engine ─────────────────────────────────────────
echo ""
echo "=== 9. Compute Engine VMs ==="
# Show name, zone, status, machine type, internal IP, external IP, tags
gcloud compute instances list \
  --project="$PROJECT_ID" \
  --format="table(
    name,
    zone.basename(),
    status,
    machineType.basename(),
    networkInterfaces[0].networkIP:label=INTERNAL_IP,
    networkInterfaces[0].accessConfigs[0].natIP:label=EXTERNAL_IP,
    tags.items.list():label=TAGS
  )" 2>/dev/null || true

echo ""
echo "=== 9-sec. VM external IP check ==="
gcloud compute instances list \
  --project="$PROJECT_ID" \
  --format="value(name,networkInterfaces[0].accessConfigs[0].natIP)" \
  2>/dev/null | \
while IFS=$'\t' read -r name ext_ip; do
  if [ -n "$ext_ip" ] && [ "$ext_ip" != "None" ]; then
    warn "VM HAS EXTERNAL IP: $name → $ext_ip"
  else
    echo "  OK: $name has no external IP"
  fi
done

echo ""
echo "=== 9b. Compute Engine disks ==="
gcloud compute disks list \
  --project="$PROJECT_ID" \
  --format="yaml(name,sizeGb,type,zone,sourceImage,status)" 2>/dev/null || true

run "9c. Instance groups" \
  gcloud compute instance-groups list \
    --project="$PROJECT_ID" \
    --format="table(name,zone,size)"

run "9d. Instance templates" \
  gcloud compute instance-templates list \
    --project="$PROJECT_ID" \
    --format="table(name,machineType,creationTimestamp)"

# ── 10. GKE ───────────────────────────────────────────────────
run "10. GKE clusters" \
  gcloud container clusters list \
    --project="$PROJECT_ID" \
    --format="table(name,location,status,currentMasterVersion,currentNodeCount,autopilot.enabled)"

echo ""
echo "=== 10b. GKE clusters – detailed specs ==="
for line in $(gcloud container clusters list \
    --project="$PROJECT_ID" \
    --format="value(name,location)" 2>/dev/null | tr '\t' ':'); do
  name="${line%%:*}"; location="${line##*:}"
  echo "--- Cluster: $name ($location) ---"
  gcloud container clusters describe "$name" \
    --location="$location" --project="$PROJECT_ID" \
    --format="yaml(nodeConfig,nodePools,autoscaling,masterAuthorizedNetworksConfig,networkConfig,privateClusterConfig)" \
    2>/dev/null || true
done

# ── 11. Cloud Functions ───────────────────────────────────────
run "11. Cloud Functions gen1" \
  gcloud functions list \
    --project="$PROJECT_ID" \
    --format="table(name,region,status,runtime,trigger)"

run "11b. Cloud Functions gen2" \
  gcloud functions list \
    --project="$PROJECT_ID" --gen2 \
    --format="table(name,region,state,runtime)"

# ── 12. Redis / Memorystore ───────────────────────────────────
echo ""
echo "=== 12. Redis instances (Memorystore) – all regions ==="
REDIS_REGIONS=(europe-west1 europe-west2 europe-west4 us-central1 us-east1)
for r in "${REDIS_REGIONS[@]}"; do
  result=$(gcloud redis instances list \
    --project="$PROJECT_ID" --region="$r" \
    --format="table(name,region,tier,memorySizeGb,state)" 2>/dev/null || true)
  if echo "$result" | grep -qv "^Listed\|^NAME\|^$"; then
    echo "--- Region: $r ---"
    echo "$result"
  fi
done

# ── 13. Pub/Sub ───────────────────────────────────────────────
run "13. Pub/Sub topics" \
  gcloud pubsub topics list \
    --project="$PROJECT_ID" \
    --format="table(name)"

run "13b. Pub/Sub subscriptions" \
  gcloud pubsub subscriptions list \
    --project="$PROJECT_ID" \
    --format="table(name,topic,ackDeadlineSeconds,messageRetentionDuration,expirationPolicy)"

# ── 14. Secret Manager ────────────────────────────────────────
run "14. Secrets" \
  gcloud secrets list \
    --project="$PROJECT_ID" \
    --format="yaml(name,replication,labels,createTime)"

echo ""
echo "=== 14b. Secrets – check for old versions ==="
for secret in $(gcloud secrets list \
    --project="$PROJECT_ID" --format="value(name)" 2>/dev/null \
    | sed 's|projects/[^/]*/secrets/||'); do
  version_count=$(gcloud secrets versions list "$secret" \
    --project="$PROJECT_ID" \
    --format="value(name)" 2>/dev/null | wc -l || echo 0)
  if [ "$version_count" -gt 5 ]; then
    warn "Secret $secret has $version_count versions — consider cleanup"
  fi
done

# ── 15. IAM ───────────────────────────────────────────────────
run "15. IAM project policy" \
  gcloud projects get-iam-policy "$PROJECT_ID" --format="yaml"

run "15b. Service accounts" \
  gcloud iam service-accounts list \
    --project="$PROJECT_ID" \
    --format="table(email,displayName,disabled)"

echo ""
echo "=== 15c. Service account keys – flag old or user-managed keys ==="
for sa in $(gcloud iam service-accounts list \
    --project="$PROJECT_ID" --format="value(email)" 2>/dev/null); do
  keys=$(gcloud iam service-accounts keys list \
    --iam-account="$sa" --project="$PROJECT_ID" \
    --managed-by=user \
    --format="table(name,validAfterTime,validBeforeTime)" 2>/dev/null || true)
  if echo "$keys" | grep -qv "^NAME\|^$\|^Listed"; then
    warn "USER-MANAGED KEY on $sa:"
    echo "$keys"
  fi
done

echo ""
echo "=== 15d. IAM check – flag overly broad roles ==="
gcloud projects get-iam-policy "$PROJECT_ID" \
  --format="value(bindings.role,bindings.members)" 2>/dev/null | \
while IFS=$'\t' read -r role members; do
  if echo "$role" | grep -qE "roles/owner|roles/editor"; then
    warn "BROAD ROLE: $role assigned to: $members"
  fi
done

# ── 16. Cloud Build ───────────────────────────────────────────
run "16. Cloud Build triggers" \
  gcloud builds triggers list \
    --project="$PROJECT_ID" \
    --format="yaml(name,description,github,triggerTemplate,build.steps[0].name)"

# ── 17. Logging ───────────────────────────────────────────────
run "17. Logging sinks" \
  gcloud logging sinks list --project="$PROJECT_ID"

run "17b. Log-based metrics" \
  gcloud logging metrics list \
    --project="$PROJECT_ID" \
    --format="table(name,description)"

run "17c. Logging buckets" \
  gcloud logging buckets list \
    --project="$PROJECT_ID" \
    --format="table(name,location,retentionDays,locked)"

# ── 18. Monitoring ────────────────────────────────────────────
run "18. Monitoring alert policies" \
  gcloud alpha monitoring policies list \
    --project="$PROJECT_ID" --format="yaml"

echo ""
echo "=== 18b. Monitoring notification channels ==="
gcloud alpha monitoring channels list \
  --project="$PROJECT_ID" --format="yaml" 2>/dev/null || \
gcloud beta monitoring channels list \
  --project="$PROJECT_ID" --format="yaml" 2>/dev/null || \
warn "Could not list notification channels (try alpha/beta manually)"

run "18c. Monitoring uptime checks" \
  gcloud monitoring uptime list-configs \
    --project="$PROJECT_ID" --format="yaml"

run "18d. Monitoring dashboards" \
  gcloud monitoring dashboards list \
    --project="$PROJECT_ID" --format="yaml"

run "18e. Monitoring services (for SLOs)" \
  gcloud monitoring services list \
    --project="$PROJECT_ID" --format="yaml"

echo ""
echo "=== 18f. SLOs per monitoring service ==="
for svc in $(gcloud monitoring services list \
    --project="$PROJECT_ID" --format="value(name)" 2>/dev/null); do
  [ -z "$svc" ] && continue
  echo "--- Service: $svc ---"
  gcloud monitoring slos list \
    --project="$PROJECT_ID" --service="$svc" \
    --format="yaml" 2>/dev/null || true
done

# ── 19. Cloud Endpoints / API Gateway ────────────────────────
run "19. Cloud Endpoints services" \
  gcloud endpoints services list \
    --project="$PROJECT_ID" \
    --format="table(serviceName,title)"

# ── 20. Security summary ──────────────────────────────────────
echo ""
echo "============================================================"
echo "SECURITY SUMMARY – items flagged during audit"
echo "============================================================"
echo "(Search for [WARN] in this file for all flagged items)"
echo ""

echo "============================================================"
echo "End of audit  |  $(date -Iseconds)"
echo "Project: $PROJECT_ID  |  Region: $REGION"
echo "Output: $OUTPUT_FILE"
echo "============================================================"

} 2>&1 | tee "$OUTPUT_FILE"

echo ""
info "Done. Full output written to: $OUTPUT_FILE"
info "Security issues: grep '\[WARN\]' $OUTPUT_FILE"
