#!/usr/bin/env bash
set -euo pipefail

die() {
  echo "Error: $*" >&2
  exit 1
}

abort_with_missing_items() {
  local -a missing_items=("$@")
  {
    echo "Missing required configuration:"
    for item in "${missing_items[@]}"; do
      echo "  - $item"
    done
    echo "Aborting."
  } >&2
  exit 1
}

on_error() {
  local line_no="$1"
  echo "Error: command failed at line ${line_no}: ${BASH_COMMAND}" >&2
}

trap 'on_error $LINENO' ERR

usage() {
  cat <<'EOF'
Bootstraps minimum Azure resources for Terraform remote state.

Usage:
  ./bootstrap_state.sh [dev|prod]

Authentication (one of):
  - Existing Azure CLI login (az login)
  - Service principal via env vars:
      ARM_CLIENT_ID
      ARM_CLIENT_SECRET
      ARM_TENANT_ID

Optional environment variables:
  ARM_SUBSCRIPTION_ID / AZURE_SUBSCRIPTION_ID   Azure subscription to target
  AZURE_LOCATION                                 Azure region (default: eastus)
  TFSTATE_RESOURCE_GROUP                         Resource group (default: rg-tfstate-ed-af-quickstart)
  TFSTATE_STORAGE_ACCOUNT                        Existing/new storage account name (must be globally unique)
  TFSTATE_STORAGE_PREFIX                         Prefix used to generate storage account name
  TFSTATE_CONTAINER_PREFIX                       Prefix for container name (default: tfstate)
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

ENVIRONMENT="${1:-${TF_ENVIRONMENT:-dev}}"
case "$ENVIRONMENT" in
  dev|prod)
    ;;
  *)
    echo "Error: environment must be 'dev' or 'prod'." >&2
    usage
    exit 1
    ;;
esac

if ! command -v az >/dev/null 2>&1; then
  die "Azure CLI (az) is not installed."
fi

LOCATION="${AZURE_LOCATION:-eastus}"
RESOURCE_GROUP="${TFSTATE_RESOURCE_GROUP:-rg-tfstate-ed-af-quickstart}"
CONTAINER_PREFIX="${TFSTATE_CONTAINER_PREFIX:-tfstate}"
CONTAINER_NAME="${CONTAINER_PREFIX}-${ENVIRONMENT}"

validate_required_inputs() {
  local supplied_sp=0
  local -a missing_items=()

  [[ -n "${ARM_CLIENT_ID:-}" ]] && supplied_sp=1
  [[ -n "${ARM_CLIENT_SECRET:-}" ]] && supplied_sp=1
  [[ -n "${ARM_TENANT_ID:-}" ]] && supplied_sp=1

  if [[ "$supplied_sp" -eq 1 ]]; then
    [[ -n "${ARM_CLIENT_ID:-}" ]] || missing_items+=("ARM_CLIENT_ID (required when using service principal authentication)")
    [[ -n "${ARM_CLIENT_SECRET:-}" ]] || missing_items+=("ARM_CLIENT_SECRET (required when using service principal authentication)")
    [[ -n "${ARM_TENANT_ID:-}" ]] || missing_items+=("ARM_TENANT_ID (required when using service principal authentication)")
  fi

  [[ -n "$LOCATION" ]] || missing_items+=("AZURE_LOCATION cannot be empty")
  [[ -n "$RESOURCE_GROUP" ]] || missing_items+=("TFSTATE_RESOURCE_GROUP cannot be empty")
  [[ -n "$CONTAINER_PREFIX" ]] || missing_items+=("TFSTATE_CONTAINER_PREFIX cannot be empty")

  if [[ ! "$CONTAINER_PREFIX" =~ ^[a-z0-9-]+$ ]]; then
    missing_items+=("TFSTATE_CONTAINER_PREFIX must only contain lowercase letters, numbers, and hyphens")
  fi

  if [[ ! "$CONTAINER_NAME" =~ ^[a-z0-9-]{3,63}$ ]]; then
    missing_items+=("Generated container name '$CONTAINER_NAME' is invalid (must be 3-63 chars, lowercase letters/numbers/hyphens)")
  fi

  if [[ -n "${TFSTATE_STORAGE_ACCOUNT:-}" && ! "${TFSTATE_STORAGE_ACCOUNT}" =~ ^[a-z0-9]{3,24}$ ]]; then
    missing_items+=("TFSTATE_STORAGE_ACCOUNT must be 3-24 lowercase letters or numbers only")
  fi

  if [[ ${#missing_items[@]} -gt 0 ]]; then
    abort_with_missing_items "${missing_items[@]}"
  fi
}

ensure_az_login() {
  local -a missing_items=()

  if ! az account show --query id -o tsv >/dev/null 2>&1; then
    missing_items+=("Azure authentication context: run 'az login' or set ARM_CLIENT_ID/ARM_CLIENT_SECRET/ARM_TENANT_ID")
  fi

  if [[ ${#missing_items[@]} -gt 0 ]]; then
    abort_with_missing_items "${missing_items[@]}"
  fi
}

login_service_principal_if_needed() {
  if [[ -n "${ARM_CLIENT_ID:-}" && -n "${ARM_CLIENT_SECRET:-}" && -n "${ARM_TENANT_ID:-}" ]]; then
    echo "Logging in with service principal from environment variables..."
    az login \
      --service-principal \
      --username "$ARM_CLIENT_ID" \
      --password "$ARM_CLIENT_SECRET" \
      --tenant "$ARM_TENANT_ID" \
      --output none
  fi
}

set_subscription_if_provided() {
  local subscription_id="${ARM_SUBSCRIPTION_ID:-${AZURE_SUBSCRIPTION_ID:-}}"
  if [[ -n "$subscription_id" ]]; then
    echo "Setting Azure subscription: $subscription_id"
    az account set --subscription "$subscription_id" --output none || \
      die "Unable to set Azure subscription '$subscription_id'. Verify the ID/name and your access."
  fi

  if ! az account show --query id -o tsv >/dev/null 2>&1; then
    abort_with_missing_items "ARM_SUBSCRIPTION_ID or AZURE_SUBSCRIPTION_ID, or set default with 'az account set --subscription <id>'"
  fi
}

sanitize_storage_name() {
  local raw="$1"
  echo "$raw" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9'
}

generate_storage_account_name() {
  local prefix random suffix candidate
  prefix="${TFSTATE_STORAGE_PREFIX:-tfstateedafqs}"
  prefix="$(sanitize_storage_name "$prefix")"
  [[ -n "$prefix" ]] || die "TFSTATE_STORAGE_PREFIX became empty after sanitization; provide letters/numbers only."
  prefix="${prefix:0:14}"
  suffix="${ENVIRONMENT}"

  for _ in {1..20}; do
    random="$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 6)"
    candidate="${prefix}${suffix}${random}"
    candidate="${candidate:0:24}"

    if [[ ${#candidate} -ge 3 ]] && az storage account check-name --name "$candidate" --query nameAvailable -o tsv | grep -qi true; then
      echo "$candidate"
      return 0
    fi
  done

  die "Could not generate a unique storage account name. Set TFSTATE_STORAGE_ACCOUNT explicitly."
}

ensure_resource_group() {
  echo "Ensuring resource group exists: $RESOURCE_GROUP ($LOCATION)"
  az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none
}

ensure_storage_account() {
  if az storage account show --name "$STORAGE_ACCOUNT" --resource-group "$RESOURCE_GROUP" >/dev/null 2>&1; then
    echo "Storage account already exists: $STORAGE_ACCOUNT"
    return 0
  fi

  echo "Creating storage account: $STORAGE_ACCOUNT"
  az storage account create \
    --name "$STORAGE_ACCOUNT" \
    --resource-group "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --sku Standard_LRS \
    --kind StorageV2 \
    --https-only true \
    --min-tls-version TLS1_2 \
    --allow-blob-public-access false \
    --output none
}

ensure_container() {
  echo "Ensuring blob container exists: $CONTAINER_NAME"
  az storage container create \
    --name "$CONTAINER_NAME" \
    --account-name "$STORAGE_ACCOUNT" \
    --auth-mode login \
    --output none
}

write_backend_file() {
  local script_dir backend_file
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  [[ -d "$script_dir/backends" ]] || die "Expected directory not found: $script_dir/backends"
  backend_file="$script_dir/backends/${ENVIRONMENT}.hcl"

  cat >"$backend_file" <<EOF
resource_group_name  = "$RESOURCE_GROUP"
storage_account_name = "$STORAGE_ACCOUNT"
container_name       = "$CONTAINER_NAME"
key                  = "af-quickstart/${ENVIRONMENT}.terraform.tfstate"
EOF

  echo "Wrote backend config: $backend_file"
}

validate_required_inputs
login_service_principal_if_needed
ensure_az_login
set_subscription_if_provided

STORAGE_ACCOUNT="${TFSTATE_STORAGE_ACCOUNT:-}"
if [[ -z "$STORAGE_ACCOUNT" ]]; then
  STORAGE_ACCOUNT="$(generate_storage_account_name)"
  echo "Generated storage account name: $STORAGE_ACCOUNT"
fi

ensure_resource_group
ensure_storage_account
ensure_container
write_backend_file

echo
echo "Bootstrap complete for environment: $ENVIRONMENT"
echo "Next command: terraform init -backend-config=backends/${ENVIRONMENT}.hcl"