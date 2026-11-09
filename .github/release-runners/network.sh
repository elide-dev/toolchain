#!/usr/bin/env bash
# Copyright the Elide Toolchain contributors.
# SPDX-License-Identifier: Apache-2.0 OR MIT
# Dedicated unpeered network, IAP-only ingress and NAT for public dependencies.
set -euo pipefail
project=elide-cloud-sandbox
network=toolchain-release
region=us-east1
gcloud services enable compute.googleapis.com iap.googleapis.com oslogin.googleapis.com --project="$project" --quiet
if ! gcloud compute networks describe "$network" --project="$project" >/dev/null 2>&1; then
  gcloud compute networks create "$network" --project="$project" --subnet-mode=custom --bgp-routing-mode=regional --quiet
fi
if ! gcloud compute networks subnets describe toolchain-release --project="$project" --region="$region" >/dev/null 2>&1; then
  gcloud compute networks subnets create toolchain-release --project="$project" --region="$region" \
    --network="$network" --range=10.250.0.0/24 --enable-flow-logs --quiet
fi
if ! gcloud compute firewall-rules describe toolchain-release-iap-ssh --project="$project" >/dev/null 2>&1; then
  gcloud compute firewall-rules create toolchain-release-iap-ssh --project="$project" \
    --network="$network" --direction=INGRESS --priority=1000 --allow=tcp:22 \
    --source-ranges=35.235.240.0/20 --enable-logging --quiet
fi
if ! gcloud compute firewall-rules describe toolchain-release-deny-private --project="$project" >/dev/null 2>&1; then
  gcloud compute firewall-rules create toolchain-release-deny-private --project="$project" \
    --network="$network" --direction=EGRESS --priority=1000 --action=DENY --rules=all \
    --destination-ranges=10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10 \
    --enable-logging --quiet
fi
if ! gcloud compute routers describe toolchain-release --project="$project" --region="$region" >/dev/null 2>&1; then
  gcloud compute routers create toolchain-release --project="$project" --region="$region" --network="$network" --quiet
fi
if ! gcloud compute routers nats describe toolchain-release --project="$project" --region="$region" --router=toolchain-release >/dev/null 2>&1; then
  gcloud compute routers nats create toolchain-release --project="$project" --region="$region" \
    --router=toolchain-release --nat-custom-subnet-ip-ranges=toolchain-release \
    --auto-allocate-nat-external-ips --enable-logging --log-filter=ERRORS_ONLY --quiet
fi
