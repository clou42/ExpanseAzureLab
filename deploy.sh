#!/bin/bash
# Manage the Expanse Azure Lab lifecycle.
#   Default      : deploy the lab (runs targeted applies in the required order)
#   --destroy    : tear the lab down again
set -e

usage() {
  cat <<'USAGE'
Usage: ./deploy.sh [options] [-- <extra terraform args>]

Modes:
  (default)              Deploy the lab (targeted applies in required order).
  --destroy, -D          Destroy the lab.

Options:
  --client-ip, -i <ip>   Set client_ip in terraform.tfvars before deploying.
  --use-current-ip       Auto-detect your public IP and use it as client_ip.
  --help, -h             Show this help.

Any unrecognized arguments are passed straight to terraform, e.g.:
  ./deploy.sh --auto-approve
  ./deploy.sh --destroy --auto-approve
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/tfscripts"

if [[ ! -f terraform.tfvars ]]; then
  echo "Error: terraform.tfvars not found. Create it from terraform.tfvars.example." >&2
  exit 1
fi

# Parse script options and pass the remainder to terraform
MODE="deploy"
TF_ARGS=()
CLIENT_IP=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --destroy|-D)
      MODE="destroy"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --)
      shift
      TF_ARGS+=("$@")
      break
      ;;
    --client-ip|-i)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --client-ip requires an IP address" >&2
        exit 1
      fi
      CLIENT_IP="$2"
      shift 2
      ;;
    --use-current-ip)
      CLIENT_IP=$(curl -s -4 --max-time 5 https://ipv4.icanhazip.com 2>/dev/null || curl -s -4 --max-time 5 https://api.ipify.org 2>/dev/null || true)
      if [[ -z "$CLIENT_IP" ]]; then
        echo "Error: Could not detect public IP. Specify manually with --client-ip <ip>." >&2
        exit 1
      fi
      echo "==> Detected public IP: $CLIENT_IP"
      shift
      ;;
    *)
      TF_ARGS+=("$1")
      shift
      ;;
  esac
done

if [[ "$MODE" == "destroy" ]]; then
  if [[ -n "$CLIENT_IP" ]]; then
    echo "Warning: --client-ip/--use-current-ip is ignored in --destroy mode" >&2
  fi
  echo "==> Destroying the lab..."
  terraform destroy "${TF_ARGS[@]}"
  echo "==> Teardown complete."
  exit 0
fi

# Update client_ip in terraform.tfvars if IP was specified and file exists
if [[ -n "$CLIENT_IP" && -f terraform.tfvars ]]; then
  if sed "s/client_ip = \"[^\"]*\"/client_ip = \"$CLIENT_IP\"/" terraform.tfvars > terraform.tfvars.tmp && mv terraform.tfvars.tmp terraform.tfvars; then
    echo "==> Updated client_ip to $CLIENT_IP in terraform.tfvars"
  else
    rm -f terraform.tfvars.tmp
    echo "Warning: Could not update terraform.tfvars" >&2
  fi
elif [[ -n "$CLIENT_IP" && ! -f terraform.tfvars ]]; then
  echo "Warning: terraform.tfvars not found, skipping client_ip update" >&2
fi

echo "==> Step 1/3: Applying azuread_user.users..."
terraform apply -target azuread_user.users "${TF_ARGS[@]}"

echo "==> Step 2/3: Applying azuread_service_principal.sp..."
terraform apply -target azuread_service_principal.sp "${TF_ARGS[@]}"

echo "==> Step 3/3: Full apply..."
terraform apply "${TF_ARGS[@]}"

echo "==> Deployment complete."
