#!/usr/bin/env bash
set -euo pipefail

USE_COLOR=true
VALIDATE_ONLY=false
VERBOSE=false

if [[ ! -t 1 || -n "${NO_COLOR:-}" ]]; then
  USE_COLOR=false
fi

if [[ "$USE_COLOR" == "true" ]]; then
  C_RESET='\033[0m'
  C_BLUE='\033[34m'
  C_GREEN='\033[32m'
  C_YELLOW='\033[33m'
  C_RED='\033[31m'
else
  C_RESET=''
  C_BLUE=''
  C_GREEN=''
  C_YELLOW=''
  C_RED=''
fi

log_step() {
  printf '%b[ ]%b %s\n' "$C_BLUE" "$C_RESET" "$*"
}

log_ok() {
  printf '%b[OK]%b %s\n' "$C_GREEN" "$C_RESET" "$*"
}

log_ok_or_skipped() {
  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    printf '%b[SKIPPED]%b %s\n' "$C_YELLOW" "$C_RESET" "$*"
    return 0
  fi

  log_ok "$@"
}

log_warn() {
  printf '%b[!]%b %s\n' "$C_YELLOW" "$C_RESET" "$*"
}

log_fail() {
  printf '%b[X]%b %s\n' "$C_RED" "$C_RESET" "$*" >&2
}

print_header() {
  printf '\n%b== %s ==%b\n' "$C_BLUE" "$*" "$C_RESET"
}

log_verbose_detail() {
  [[ "$VERBOSE" == "true" ]] || return 0
  printf '    %s: %s\n' "$1" "$2"
}

die() {
  log_fail "$*"
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
  log_fail "Command failed at line ${line_no}: ${BASH_COMMAND}"
}

trap 'on_error $LINENO' ERR

usage() {
  cat <<'EOF'
Bootstraps minimum Azure resources for Terraform remote state.

Usage:
  ./bootstrap_state.sh [--dry-run|-n] [--validate-only] [--verbose|-v] [dev|prod]

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

Flags:
  -n, --dry-run                                  Print planned actions without making changes
  --validate-only                                Run stage 1 and stage 2 only, then exit
  -v, --verbose                                  Print detailed Stage 1 configuration information

Storage account naming notes:
  - Must be 3-24 chars, lowercase letters or numbers only
  - Dashes are NOT allowed in storage account names
  - Generated format: <prefix><env><random>, e.g. tfstateafqsdeva1b2c3
EOF
}

DRY_RUN=false
ENVIRONMENT="${TF_ENVIRONMENT:-dev}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    -n|--dry-run)
      DRY_RUN=true
      shift
      ;;
    --validate-only)
      VALIDATE_ONLY=true
      shift
      ;;
    -v|--verbose)
      VERBOSE=true
      shift
      ;;
    dev|prod)
      ENVIRONMENT="$1"
      shift
      ;;
    *)
      echo "Error: unknown argument '$1'." >&2
      usage
      exit 1
      ;;
  esac
done

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
CURRENT_SUBSCRIPTION=""
STORAGE_ACCOUNT="${TFSTATE_STORAGE_ACCOUNT:-}"
STORAGE_ACCOUNT_SOURCE=""
RESOURCE_GROUP_EXISTS=false
STORAGE_ACCOUNT_EXISTS=false
CONTAINER_EXISTS=false
BACKEND_FILE_READY=false

run_or_echo() {
  if [[ "$DRY_RUN" == "true" ]]; then
    printf '%b[dry-run]%b ' "$C_YELLOW" "$C_RESET"
    printf '%q ' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

compute_storage_name_base() {
  local prefix env_segment suffix_len max_prefix_len
  prefix="${TFSTATE_STORAGE_PREFIX:-tfstateafqs}"
  prefix="$(sanitize_storage_name "$prefix")"
  [[ -n "$prefix" ]] || die "TFSTATE_STORAGE_PREFIX became empty after sanitization; provide letters/numbers only."

  env_segment="$(sanitize_storage_name "$ENVIRONMENT")"
  [[ -n "$env_segment" ]] || die "Environment value became empty after sanitization."

  suffix_len=6
  max_prefix_len=$((24 - ${#env_segment} - suffix_len))
  (( max_prefix_len >= 1 )) || die "Environment segment '$env_segment' leaves no room for prefix in storage account name."
  prefix="${prefix:0:max_prefix_len}"

  printf '%s' "${prefix}${env_segment}"
}

list_storage_accounts_with_base_prefix() {
  local base_prefix
  base_prefix="$(compute_storage_name_base)"

  az storage account list \
    --query "[?starts_with(name, '$base_prefix')].[name,resourceGroup]" \
    -o tsv 2>/dev/null || true
}

find_storage_account_with_base_prefix_in_rg() {
  local matches name rg
  matches="$(list_storage_accounts_with_base_prefix)"
  while IFS=$'\t' read -r name rg; do
    [[ -n "$name" ]] || continue
    if [[ "$rg" == "$RESOURCE_GROUP" ]]; then
      printf '%s' "$name"
      return 0
    fi
  done <<< "$matches"

  return 1
}

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

report_storage_prefix_state() {
  local base_prefix matches name rg found_in_rg=false

  base_prefix="$(compute_storage_name_base)"
  log_step "Checking for existing storage accounts with prefix '${base_prefix}*'"

  matches="$(list_storage_accounts_with_base_prefix)"
  if [[ -z "$matches" ]]; then
    log_ok "No existing storage accounts found with prefix '${base_prefix}*'"
    return 0
  fi

  log_warn "Found storage accounts with prefix '${base_prefix}*':"
  while IFS=$'\t' read -r name rg; do
    [[ -n "$name" ]] || continue
    if [[ "$rg" == "$RESOURCE_GROUP" ]]; then
      found_in_rg=true
    fi
    printf '    - %s (resource group: %s)\n' "$name" "$rg"
  done <<< "$matches"

  if [[ "$found_in_rg" == "true" ]]; then
    log_ok "A matching prefixed account exists in target resource group '$RESOURCE_GROUP'"
  else
    log_warn "No matching prefixed account exists in target resource group '$RESOURCE_GROUP'"
  fi
}

login_service_principal_if_needed() {
  if [[ -n "${ARM_CLIENT_ID:-}" && -n "${ARM_CLIENT_SECRET:-}" && -n "${ARM_TENANT_ID:-}" ]]; then
    echo "Logging in with service principal from environment variables..."
    run_or_echo az login \
      --service-principal \
      --username "$ARM_CLIENT_ID" \
      --password "$ARM_CLIENT_SECRET" \
      --tenant "$ARM_TENANT_ID" \
      --output none
  fi
}

get_requested_subscription() {
  printf '%s' "${ARM_SUBSCRIPTION_ID:-${AZURE_SUBSCRIPTION_ID:-}}"
}

detect_auth_mode() {
  if [[ -n "${ARM_CLIENT_ID:-}" && -n "${ARM_CLIENT_SECRET:-}" && -n "${ARM_TENANT_ID:-}" ]]; then
    printf '%s' "service-principal-env"
    return 0
  fi

  printf '%s' "azure-cli-login"
}

set_subscription_if_provided() {
  local subscription_id
  subscription_id="$(get_requested_subscription)"
  if [[ -n "$subscription_id" ]]; then
    echo "Setting Azure subscription: $subscription_id"
    run_or_echo az account set --subscription "$subscription_id" --output none || \
      die "Unable to set Azure subscription '$subscription_id'. Verify the ID/name and your access."
  fi

  if ! az account show --query id -o tsv >/dev/null 2>&1; then
    abort_with_missing_items "ARM_SUBSCRIPTION_ID or AZURE_SUBSCRIPTION_ID, or set default with 'az account set --subscription <id>'"
  fi
}

emit_verbose_configuration_details() {
  local auth_mode requested_subscription storage_prefix_raw storage_prefix_sanitized storage_name_base

  [[ "$VERBOSE" == "true" ]] || return 0

  auth_mode="$(detect_auth_mode)"
  requested_subscription="$(get_requested_subscription)"

  print_header "Verbose configuration details"
  log_verbose_detail "Environment" "$ENVIRONMENT"
  log_verbose_detail "Dry run" "$DRY_RUN"
  log_verbose_detail "Validate only" "$VALIDATE_ONLY"
  log_verbose_detail "Azure location" "$LOCATION"
  log_verbose_detail "Resource group" "$RESOURCE_GROUP"
  log_verbose_detail "Container prefix" "$CONTAINER_PREFIX"
  log_verbose_detail "Container name" "$CONTAINER_NAME"
  log_verbose_detail "Authentication mode" "$auth_mode"

  if [[ "$auth_mode" == "service-principal-env" ]]; then
    log_verbose_detail "Service principal inputs" "ARM_CLIENT_ID, ARM_CLIENT_SECRET, and ARM_TENANT_ID are set"
  fi

  if [[ -n "$requested_subscription" ]]; then
    log_verbose_detail "Requested subscription" "$requested_subscription"
  else
    log_verbose_detail "Requested subscription" "(using current Azure CLI default)"
  fi

  log_verbose_detail "Resolved subscription" "$CURRENT_SUBSCRIPTION"

  if [[ -n "$STORAGE_ACCOUNT" ]]; then
    log_verbose_detail "Storage account selection" "explicit"
    log_verbose_detail "Storage account name" "$STORAGE_ACCOUNT"
    return 0
  fi

  storage_prefix_raw="${TFSTATE_STORAGE_PREFIX:-tfstateafqs}"
  storage_prefix_sanitized="$(sanitize_storage_name "$storage_prefix_raw")"
  storage_name_base="$(compute_storage_name_base)"

  log_verbose_detail "Storage account selection" "derived from naming prefix"
  log_verbose_detail "Storage prefix (raw)" "$storage_prefix_raw"
  log_verbose_detail "Storage prefix (sanitized)" "$storage_prefix_sanitized"
  log_verbose_detail "Storage name base" "${storage_name_base}*"
  log_verbose_detail "Storage name resolution" "Stage 2 will reuse an existing match in '$RESOURCE_GROUP' or generate a unique name"
}

resolve_current_subscription() {
  local sub_name sub_id
  sub_name="$(az account show --query name -o tsv 2>/dev/null || true)"
  sub_id="$(az account show --query id -o tsv 2>/dev/null || true)"

  if [[ -n "$sub_name" && -n "$sub_id" ]]; then
    CURRENT_SUBSCRIPTION="${sub_name} (${sub_id})"
  elif [[ -n "$sub_id" ]]; then
    CURRENT_SUBSCRIPTION="$sub_id"
  else
    CURRENT_SUBSCRIPTION="unknown"
  fi
}

sanitize_storage_name() {
  local raw="$1"
  echo "$raw" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9'
}

generate_storage_account_name() {
  local prefix env_segment random suffix_len max_prefix_len candidate
  prefix="${TFSTATE_STORAGE_PREFIX:-tfstateafqs}"
  prefix="$(sanitize_storage_name "$prefix")"
  [[ -n "$prefix" ]] || die "TFSTATE_STORAGE_PREFIX became empty after sanitization; provide letters/numbers only."
  env_segment="$(sanitize_storage_name "$ENVIRONMENT")"
  [[ -n "$env_segment" ]] || die "Environment value became empty after sanitization."

  # Keep output human-readable: prefix + environment + random suffix.
  # Azure Storage account names are limited to 24 chars.
  suffix_len=6
  max_prefix_len=$((24 - ${#env_segment} - suffix_len))
  (( max_prefix_len >= 1 )) || die "Environment segment '$env_segment' leaves no room for prefix in storage account name."
  prefix="${prefix:0:max_prefix_len}"

  for _ in {1..20}; do
    random="$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 6)"
    candidate="${prefix}${env_segment}${random}"

    if [[ ${#candidate} -ge 3 ]] && az storage account check-name --name "$candidate" --query nameAvailable -o tsv | grep -qi true; then
      echo "$candidate"
      return 0
    fi
  done

  die "Could not generate a unique storage account name. Set TFSTATE_STORAGE_ACCOUNT explicitly."
}

abort_with_missing_resources() {
  local -a missing_resources=("$@")
  {
    echo "Missing required resources:"
    for item in "${missing_resources[@]}"; do
      echo "  - $item"
    done
    echo "Aborting."
  } >&2
  exit 1
}

prompt_yes_no() {
  local prompt="$1"
  local reply

  if [[ ! -t 0 ]]; then
    log_warn "Skipping prompt because stdin is not interactive."
    return 1
  fi

  while true; do
    read -r -p "$prompt [y/N]: " reply
    case "$reply" in
      [Yy]|[Yy][Ee][Ss])
        return 0
        ;;
      ""|[Nn]|[Nn][Oo])
        return 1
        ;;
      *)
        log_warn "Please answer yes or no."
        ;;
    esac
  done
}

resolve_storage_account_name() {
  if [[ -n "$STORAGE_ACCOUNT" ]]; then
    if [[ -z "$STORAGE_ACCOUNT_SOURCE" ]]; then
      STORAGE_ACCOUNT_SOURCE="explicit"
      log_ok "Using requested storage account: $STORAGE_ACCOUNT"
    fi
    return 0
  fi

  STORAGE_ACCOUNT="$(find_storage_account_with_base_prefix_in_rg || true)"
  if [[ -n "$STORAGE_ACCOUNT" ]]; then
    STORAGE_ACCOUNT_SOURCE="existing-prefix"
    log_ok "Reusing existing storage account with matching prefix: $STORAGE_ACCOUNT"
    return 0
  fi

  STORAGE_ACCOUNT="$(generate_storage_account_name)"
  STORAGE_ACCOUNT_SOURCE="generated"
  log_ok "Planned storage account name: $STORAGE_ACCOUNT"
}

inspect_resource_group_state() {
  local exists

  exists="$(az group exists --name "$RESOURCE_GROUP" 2>/dev/null || true)"
  if [[ "$exists" == "true" ]]; then
    RESOURCE_GROUP_EXISTS=true
  else
    RESOURCE_GROUP_EXISTS=false
  fi
}

inspect_storage_account_state() {
  local existing_rg

  existing_rg="$(az storage account list --query "[?name=='$STORAGE_ACCOUNT'].resourceGroup | [0]" -o tsv 2>/dev/null || true)"
  if [[ -n "$existing_rg" && "$existing_rg" != "$RESOURCE_GROUP" ]]; then
    die "Storage account '$STORAGE_ACCOUNT' already exists in resource group '$existing_rg'. Set TFSTATE_STORAGE_ACCOUNT to an account in '$RESOURCE_GROUP' or choose a different name/prefix."
  fi

  if [[ -n "$existing_rg" ]]; then
    STORAGE_ACCOUNT_EXISTS=true
  else
    STORAGE_ACCOUNT_EXISTS=false
  fi
}

inspect_container_state() {
  local exists

  if [[ "$STORAGE_ACCOUNT_EXISTS" != "true" ]]; then
    CONTAINER_EXISTS=false
    return 0
  fi

  exists="$(az storage container exists \
    --name "$CONTAINER_NAME" \
    --account-name "$STORAGE_ACCOUNT" \
    --auth-mode login \
    --query exists -o tsv 2>/dev/null || true)"

  if [[ "$exists" == "true" ]]; then
    CONTAINER_EXISTS=true
  else
    CONTAINER_EXISTS=false
  fi
}

run_resource_checks() {
  local require_all="$1"
  local header="$2"
  local -a missing_resources=()

  print_header "$header"
  log_ok "Azure subscription: ${CURRENT_SUBSCRIPTION}"
  report_storage_prefix_state
  resolve_storage_account_name
  inspect_resource_group_state
  inspect_storage_account_state
  inspect_container_state

  if [[ "$RESOURCE_GROUP_EXISTS" == "true" ]]; then
    log_ok "Resource group exists: $RESOURCE_GROUP"
  else
    log_warn "Resource group missing: $RESOURCE_GROUP"
    if [[ "$require_all" == "true" ]]; then
      missing_resources+=("Resource group '$RESOURCE_GROUP'")
    fi
  fi

  if [[ "$STORAGE_ACCOUNT_EXISTS" == "true" ]]; then
    log_ok "Storage account exists: $STORAGE_ACCOUNT"
  else
    log_warn "Storage account missing: $STORAGE_ACCOUNT"
    if [[ "$require_all" == "true" ]]; then
      missing_resources+=("Storage account '$STORAGE_ACCOUNT' in resource group '$RESOURCE_GROUP'")
    else
      log_step "Storage account will be created in stage 3: $STORAGE_ACCOUNT"
    fi
  fi

  if [[ "$STORAGE_ACCOUNT_EXISTS" != "true" ]]; then
    log_warn "Container check deferred until storage account exists: $CONTAINER_NAME"
  elif [[ "$CONTAINER_EXISTS" == "true" ]]; then
    log_ok "Blob container exists: $CONTAINER_NAME"
  else
    log_warn "Blob container missing: $CONTAINER_NAME"
    if [[ "$require_all" == "true" ]]; then
      missing_resources+=("Blob container '$CONTAINER_NAME' in storage account '$STORAGE_ACCOUNT'")
    else
      log_step "Blob container will be created in stage 3: $CONTAINER_NAME"
    fi
  fi

  if [[ "$require_all" == "true" && ${#missing_resources[@]} -gt 0 ]]; then
    abort_with_missing_resources "${missing_resources[@]}"
  fi

  log_ok "Resource checks completed"
}

create_resource_group_if_missing() {
  if [[ "$RESOURCE_GROUP_EXISTS" == "true" ]]; then
    log_ok "Resource group already exists: $RESOURCE_GROUP"
    return 0
  fi

  log_step "Creating resource group: $RESOURCE_GROUP ($LOCATION)"
  run_or_echo az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none
  log_ok_or_skipped "Resource group ready: $RESOURCE_GROUP"
}

create_storage_account_if_missing() {
  if [[ "$STORAGE_ACCOUNT_EXISTS" == "true" ]]; then
    log_ok "Storage account already exists: $STORAGE_ACCOUNT"
    return 0
  fi

  log_step "Creating storage account: $STORAGE_ACCOUNT"
  run_or_echo az storage account create \
    --name "$STORAGE_ACCOUNT" \
    --resource-group "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --sku Standard_LRS \
    --kind StorageV2 \
    --https-only true \
    --min-tls-version TLS1_2 \
    --allow-blob-public-access false \
    --output none
  log_ok_or_skipped "Storage account ready: $STORAGE_ACCOUNT"
}

create_container_if_missing() {
  if [[ "$CONTAINER_EXISTS" == "true" ]]; then
    log_ok "Blob container already exists: $CONTAINER_NAME"
    return 0
  fi

  log_step "Creating blob container: $CONTAINER_NAME"
  run_or_echo az storage container create \
    --name "$CONTAINER_NAME" \
    --account-name "$STORAGE_ACCOUNT" \
    --auth-mode login \
    --output none
  log_ok_or_skipped "Container ready: $CONTAINER_NAME"
}

stage_1_validate_inputs_and_configuration() {
  print_header "Stage 1: Validate inputs and configuration"
  validate_required_inputs
  log_ok "Input validation passed"
  login_service_principal_if_needed
  ensure_az_login
  log_ok "Azure authentication context is available"
  set_subscription_if_provided
  resolve_current_subscription
  log_ok "Azure subscription: ${CURRENT_SUBSCRIPTION}"
  emit_verbose_configuration_details
}

stage_2_check_existing_resources() {
  run_resource_checks "$1" "Stage 2: Check required resources"
}

stage_3_create_missing_resources() {
  print_header "Stage 3: Create missing resources"
  create_resource_group_if_missing
  create_storage_account_if_missing
  create_container_if_missing

  if [[ "$DRY_RUN" == "true" ]]; then
    log_ok "Dry-run mode: no Azure resources were changed."
  else
    log_ok "Resource creation completed"
  fi
}

stage_4_validate_created_resources() {
  run_resource_checks "true" "Stage 4: Validate created resources"
}

maybe_write_backend_file() {
  local script_dir backend_file desired_content
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  [[ -d "$script_dir/backends" ]] || die "Expected directory not found: $script_dir/backends"
  backend_file="$script_dir/backends/${ENVIRONMENT}.hcl"

  desired_content="resource_group_name  = \"$RESOURCE_GROUP\"
storage_account_name = \"$STORAGE_ACCOUNT\"
container_name       = \"$CONTAINER_NAME\"
key                  = \"af-quickstart/${ENVIRONMENT}.terraform.tfstate\""

  if [[ -f "$backend_file" ]] && [[ "$(<"$backend_file")" == "$desired_content" ]]; then
    BACKEND_FILE_READY=true
    log_ok "Backend config already up to date: $backend_file"
    return 0
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    printf '%b[dry-run]%b Would prompt to write backend config: %s\n' "$C_YELLOW" "$C_RESET" "$backend_file"
    printf '%b[dry-run]%b ---\n' "$C_YELLOW" "$C_RESET"
    echo "$desired_content"
    printf '%b[dry-run]%b ---\n' "$C_YELLOW" "$C_RESET"
    return 0
  fi

  if ! prompt_yes_no "Create or update backend config '$backend_file'?"; then
    log_warn "Skipped backend config write: $backend_file"
    return 0
  fi

  printf '%s\n' "$desired_content" >"$backend_file"

  BACKEND_FILE_READY=true
  log_ok "Wrote backend config: $backend_file"
}

print_header "Bootstrap Terraform Remote State"
log_step "Environment: $ENVIRONMENT"

stage_1_validate_inputs_and_configuration
stage_2_check_existing_resources "$VALIDATE_ONLY"

if [[ "$VALIDATE_ONLY" == "true" ]]; then
  echo
  log_ok "Validation-only mode complete. No resources or files were changed."
  exit 0
fi

stage_3_create_missing_resources

if [[ "$DRY_RUN" != "true" ]]; then
  stage_4_validate_created_resources

  print_header "Backend config"
  maybe_write_backend_file
fi

echo
print_header "Complete"
log_ok "Bootstrap complete for environment: $ENVIRONMENT"
if [[ "$DRY_RUN" == "true" ]]; then
  log_ok "Dry-run mode: no Azure or local file changes were made."
elif [[ "$BACKEND_FILE_READY" == "true" ]]; then
  printf 'Next command: terraform init -backend-config=backends/%s.hcl\n' "$ENVIRONMENT"
else
  log_warn "Backend config was not written. Create backends/${ENVIRONMENT}.hcl before running terraform init."
fi
