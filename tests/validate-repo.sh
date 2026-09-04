#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

required=(
  README.md REQUIREMENTS.md ATTRIBUTION.md LICENSE
  infra/.terraform.lock.hcl infra/versions.tf infra/variables.tf infra/locals.tf infra/checkpoint.tf
  infra/vendor/README.md infra/vendor/vendor-checksums.sha256
  infra/vendor/checkpoint-cloudguard-network-security/LICENSE
  infra/vendor/checkpoint-cloudguard-network-security/PATCHES.md
  infra/networking.tf infra/workloads.tf infra/management.tf infra/logging.tf infra/outputs.tf
  infra/tests/demo.tftest.hcl infra/tests/r81-module.tftest.hcl
  configs/demo.tfvars.example
  cloud-init/workload.yaml cloud-init/collector.yaml
  scripts/lib.sh scripts/preflight.sh scripts/plan.sh scripts/deploy.sh scripts/test.sh
  scripts/migrate-tfvars.sh
  scripts/publish-vhd-image.sh
  scripts/verify-vendor.sh
  scripts/configure-policy.sh scripts/checkpoint-policy.sh scripts/inspect-checkpoint.sh
  scripts/enable-audit-export.sh
  scripts/validate-data-nsg.py
  scripts/vm-case.sh scripts/run-tests.sh scripts/render-test-report.py scripts/validate-existing.sh
  scripts/query-logs.sh
  scripts/lock-worm.sh scripts/destroy.sh
  docs/architecture.md docs/drawio-architecture.md docs/network-ip-plan.md
  docs/cloudguard-image-export.md
  docs/post-deployment-validation.md
  docs/r81-image-e2e-test-and-operations.md
  docs/r82-image-e2e-test-and-operations.md
  docs/validated-results.md
  docs/checkpoint-cloudguard-byol-architecture.drawio
  docs/checkpoint-cloudguard-byol-test-architecture.svg
  docs/requirement-mapping.md docs/policy-runbook.md docs/test-matrix.md
)

for file in "${required[@]}"; do
  [[ -f "$ROOT/$file" ]] || {
    echo "Missing required file: $file" >&2
    exit 1
  }
done

grep -q 'source = "./vendor/checkpoint-cloudguard-network-security/modules/single-gateway"' "$ROOT/infra/checkpoint.tf"
! grep -q 'source.*CheckPointSW/cloudguard-network-security' "$ROOT/infra/checkpoint.tf"
! grep -q 'module "regions"' "$ROOT/infra/vendor/checkpoint-cloudguard-network-security/modules/common/common/main.tf"
! grep -q '^provider "azurerm"' "$ROOT/infra/vendor/checkpoint-cloudguard-network-security/modules/single-gateway/versions.tf"
grep -q 'default     = "Standard_D8s_v5"' "$ROOT/infra/variables.tf"
grep -q 'default     = "Standard_D4ls_v6"' "$ROOT/infra/variables.tf"
grep -q 'default     = "example.org"' "$ROOT/infra/variables.tf"
grep -q 'subscription_id.*00000000-0000-0000-0000-000000000000' "$ROOT/configs/demo.tfvars.example"
if grep -RInE --include='*.tf' 'source[[:space:]]*=[[:space:]]*"[A-Za-z0-9_-]+/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+"' "$ROOT/infra/vendor"; then
  echo "Vendored module still contains a remote registry module source." >&2
  exit 1
fi

if grep -RIn \
  --exclude-dir=.git \
  --exclude-dir=.terraform \
  --exclude-dir=.local \
  --exclude-dir=evidence \
  --exclude='*.tfstate*' \
  -i 'v[i]vo' "$ROOT"; then
  echo "Customer-specific naming found; the standalone demo must remain generic." >&2
  exit 1
fi
grep -q 'installation_type.*= "standalone"' "$ROOT/infra/checkpoint.tf"
grep -q 'vm_os_sku.*= local.checkpoint_plan' "$ROOT/infra/checkpoint.tf"
grep -q 'source_image_id.*= trimspace(var.checkpoint_image_id)' "$ROOT/infra/checkpoint.tf"
grep -q 'source_image_requires_plan.*= local.checkpoint_source_requires_plan' "$ROOT/infra/checkpoint.tf"
grep -q 'variable "checkpoint_image_id"' "$ROOT/infra/variables.tf"
grep -q 'variable "checkpoint_image_requires_plan"' "$ROOT/infra/variables.tf"
grep -q 'R81 Management API 1.7 cannot automate' "$ROOT/infra/variables.tf"
grep -q 'variable "r81_tls_manually_configured"' "$ROOT/infra/variables.tf"
grep -q 'R82/R8210 custom images must retain' "$ROOT/infra/variables.tf"
grep -q 'if \[\[ "\$source_requires_plan" == "true" \]\]' "$ROOT/scripts/deploy.sh"
grep -q -- '--checkpoint-release R81|R82|R8210' "$ROOT/scripts/publish-vhd-image.sh"
grep -q 'marketplace-plan-required' "$ROOT/scripts/preflight.sh"
grep -q 'join("\\u001f")' "$ROOT/scripts/preflight.sh"
grep -q 'CHECKPOINT_SSH_WAIT_SECONDS' "$ROOT/scripts/configure-policy.sh"
grep -q 'CHECKPOINT_RECONCILE_SSH_RULE' "$ROOT/scripts/configure-policy.sh"
grep -q 'CHECKPOINT_TLS_CA_FILE' "$ROOT/scripts/configure-policy.sh"
grep -q 'CHECKPOINT_TRANSPORT:-ssh' "$ROOT/scripts/configure-policy.sh"
! grep -q 'skip_policy_configuration.value // true' "$ROOT/scripts/configure-policy.sh"
grep -q 'ensure_restricted_ssh_nsg_rules' "$ROOT/scripts/lib.sh"
grep -q 'remove_temporary_restricted_ssh_nsg_rule' "$ROOT/scripts/lib.sh"
grep -q 'Failed to remove temporary SSH rule' "$ROOT/scripts/lib.sh"
grep -q 'checkpoint-demo-ssh' "$ROOT/scripts/lib.sh"
grep -q 'CHECKPOINT_RECONCILE_SSH_RULE' "$ROOT/scripts/run-tests.sh"
grep -q 'DenyOtherVnetManagement' "$ROOT/scripts/run-tests.sh"
grep -q 'checkpoint_management_nic_id' "$ROOT/scripts/run-tests.sh"
grep -q 'T17-data-plane-nsg-rules.json' "$ROOT/scripts/run-tests.sh"
grep -q 'validate_no_public_management_rules' "$ROOT/scripts/run-tests.sh"
python3 "$ROOT/scripts/validate-data-nsg.py" --self-test
grep -q -- '--outputs-file' "$ROOT/scripts/configure-policy.sh" "$ROOT/scripts/run-tests.sh"
grep -q 'CloudGuard 部署验证报告' "$ROOT/scripts/render-test-report.py"
grep -q 'report.html' "$ROOT/scripts/render-test-report.py"
grep -q -- '--ca-file' "$ROOT/scripts/validate-existing.sh"
! grep -q -- '--configure-policy' "$ROOT/scripts/validate-existing.sh"
grep -q 'RECONCILED' "$ROOT/scripts/run-tests.sh" "$ROOT/scripts/render-test-report.py"
grep -q 'unset outputs' "$ROOT/scripts/configure-policy.sh" "$ROOT/scripts/run-tests.sh"
grep -Fq "SyslogMessage contains 'action=\\\"Accept\\\"'" "$ROOT/scripts/run-tests.sh"
grep -q 'COMMAND=' "$ROOT/scripts/vm-case.sh"
grep -q 'wait_for_command cp_log_export' "$ROOT/scripts/checkpoint-policy.sh"
grep -q 'api set group' "$ROOT/scripts/checkpoint-policy.sh"
grep -q 'name "${RULE_PREFIX}Hide Protected Networks"' "$ROOT/scripts/checkpoint-policy.sh"
grep -q 'name "${RULE_PREFIX}No NAT Protected Networks"' "$ROOT/scripts/checkpoint-policy.sh"
grep -q 'INBOUND_SOURCE_CIDR" == "$MANAGEMENT_CIDR' "$ROOT/scripts/checkpoint-policy.sh"
grep -q 'narrow exception' "$ROOT/docs/policy-runbook.md" || grep -q '窄例外' "$ROOT/docs/policy-runbook.md"
grep -q 'name "${RULE_PREFIX}Block DNS Domains"' "$ROOT/scripts/checkpoint-policy.sh"
grep -q 'urls-defined-as-regular-expression true' "$ROOT/scripts/checkpoint-policy.sh"
! grep -q 'nat-hide-internal-interfaces true' "$ROOT/scripts/checkpoint-policy.sh"
grep -q 'LOG_INGEST_WAIT_SECONDS' "$ROOT/scripts/run-tests.sh"
grep -q 'Deleting a stale recovered data export' "$ROOT/scripts/enable-audit-export.sh"
grep -q 'SYSLOG_TABLE_WAIT_SECONDS' "$ROOT/scripts/enable-audit-export.sh"
grep -Fq -- "--query '[0].Count'" "$ROOT/scripts/enable-audit-export.sh"
! grep -q 'elif (.tables?' "$ROOT/scripts/enable-audit-export.sh"
grep -q 'windows_client_size.*var.windows_client_vm_size' "$ROOT/scripts/preflight.sh"
grep -q 'nameopt RFC2253' "$ROOT/scripts/run-tests.sh"
grep -q '"arg4=\$EXPECTED_CA_ISSUER_ARG"' "$ROOT/scripts/run-tests.sh"
grep -q '15 PASS / 1 SKIP' "$ROOT/docs/r81-image-e2e-test-and-operations.md"
grep -q '12 PASS / 1 SKIP' "$ROOT/docs/r82-image-e2e-test-and-operations.md"
grep -q 'validate-existing.sh' "$ROOT/docs/post-deployment-validation.md"
grep -q 'report.html' "$ROOT/docs/post-deployment-validation.md"
grep -q 'scheme="http"' "$ROOT/scripts/vm-case.sh"
! grep -q '"${var_args\[@\]}"' "$ROOT/scripts/deploy.sh"
! grep -q '"${args\[@\]}"' "$ROOT/scripts/plan.sh" "$ROOT/scripts/destroy.sh"
grep -q 'Marketplace must remain the default Check Point image source' "$ROOT/infra/tests/demo.tftest.hcl"
grep -q 'r81_planless_full_module_plan' "$ROOT/infra/tests/r81-module.tftest.hcl"
grep -q '"cgi-mgmt-r81"' "$ROOT/infra/vendor/checkpoint-cloudguard-network-security/modules/common/common/variables.tf"
grep -q 'example-gallery/images/checkpoint-r82-byol/versions/1.0.0' "$ROOT/configs/demo.tfvars.example"
grep -q 'mgmt-byol' "$ROOT/infra/locals.tf"
grep -q 'variable "management_cidrs"' "$ROOT/infra/variables.tf"
grep -q 'cidrhost(cidr, 0) == split("/", cidr)\[0\]' "$ROOT/infra/variables.tf"
grep -q 'output "management_cidrs"' "$ROOT/infra/outputs.tf"
grep -q 'source_address_prefixes.*local.management_cidrs' "$ROOT/infra/locals.tf"
grep -q 'default     = \[\]' "$ROOT/infra/variables.tf"
grep -q 'management_private_ip.*local.gateway_management_ip' "$ROOT/infra/checkpoint.tf"
grep -q 'network_interface_ids.*management.id.*nic.id.*nic1.id' \
  "$ROOT/infra/vendor/checkpoint-cloudguard-network-security/modules/single-gateway/main.tf"
grep -q 'primary_network_interface_id.*management.id' \
  "$ROOT/infra/vendor/checkpoint-cloudguard-network-security/modules/single-gateway/main.tf"
grep -q 'name.*-management' "$ROOT/infra/vendor/checkpoint-cloudguard-network-security/modules/single-gateway/main.tf"
grep -q 'name.*-frontend' "$ROOT/infra/vendor/checkpoint-cloudguard-network-security/modules/single-gateway/main.tf"
grep -q 'name.*-backend' "$ROOT/infra/vendor/checkpoint-cloudguard-network-security/modules/single-gateway/main.tf"
grep -q 'cp_conf client createlist' "$ROOT/scripts/checkpoint-policy.sh"
grep -q 'MANAGEMENT_POLICY_SOURCE="Any"' "$ROOT/scripts/checkpoint-policy.sh"
grep -q 'default-via-checkpoint' "$ROOT/infra/networking.tf"
grep -q 'remote-spoke-via-checkpoint' "$ROOT/infra/networking.tf"
grep -q 'eu-spoke-via-checkpoint' "$ROOT/infra/networking.tf"
grep -q 'allow_forwarded_traffic.*= true' "$ROOT/infra/networking.tf"
grep -q 'resource "azurerm_windows_virtual_machine" "management"' "$ROOT/infra/management.tf"
grep -q 'resource "azurerm_bastion_host" "management"' "$ROOT/infra/management.tf"
grep -q 'name.*= "AzureBastionSubnet"' "$ROOT/infra/management.tf"
grep -q 'source_address_prefix.*= var.bastion_subnet_prefix' "$ROOT/infra/management.tf"
grep -q 'azurerm_network_interface_security_group_association.*windows_client' "$ROOT/infra/management.tf"
! grep -q 'azurerm_subnet_network_security_group_association.*windows_client' "$ROOT/infra/management.tf"
grep -q 'write_terraform_outputs' "$ROOT/scripts/deploy.sh" "$ROOT/scripts/enable-audit-export.sh"
grep -q 'table_names.*= \["Syslog"\]' "$ROOT/infra/logging.tf"
grep -q 'count = var.enable_log_data_export ? 1 : 0' "$ROOT/infra/logging.tf"
grep -q 'am-syslog' "$ROOT/infra/logging.tf"
grep -q 'allowProtectedAppendWrites.*= true' "$ROOT/infra/logging.tf"
grep -q 'state.*= "Unlocked"' "$ROOT/infra/logging.tf"
grep -q 'publicNetworkAccess.*= "Disabled"' "$ROOT/infra/logging.tf"
grep -q 'enable-https-inspection true' "$ROOT/scripts/checkpoint-policy.sh"
grep -q 'add outbound-inspection-certificate' "$ROOT/scripts/checkpoint-policy.sh"
grep -q 'show updatable-objects-repository-content' "$ROOT/scripts/checkpoint-policy.sh"
grep -q 'set static-route' "$ROOT/scripts/checkpoint-policy.sh"
grep -q 'MANAGEMENT_AZURE_GATEWAY' "$ROOT/scripts/checkpoint-policy.sh"
grep -q 'cp_log_export add' "$ROOT/scripts/checkpoint-policy.sh"
grep -q -- '--enable-audit-export' "$ROOT/scripts/deploy.sh"
grep -q -- '--lock-worm' "$ROOT/scripts/deploy.sh"
grep -q 'enable-audit-export.sh' "$ROOT/scripts/deploy.sh"
! grep -q 'configure-policy.sh' "$ROOT/scripts/deploy.sh"
! grep -q 'terraform.*test' "$ROOT/scripts/preflight.sh"
grep -Fq '"$TERRAFORM" -chdir="$INFRA" test' "$ROOT/scripts/test.sh"
grep -q -- '--yes' "$ROOT/scripts/lock-worm.sh"
grep -q 'CONFIRM_DESTROY' "$ROOT/scripts/destroy.sh"
grep -q 'permanently_delete_on_destroy.*= true' "$ROOT/infra/versions.tf"
grep -q 'terraform_state_has' "$ROOT/scripts/deploy.sh" "$ROOT/scripts/enable-audit-export.sh"
grep -q '^\.local/' "$ROOT/.gitignore"

if git -C "$ROOT" grep -IlE \
  '(client_secret|admin_password|ARM_CLIENT_SECRET)[[:space:]]*=[[:space:]]*"[^"]+"' \
  -- '*.tf' '*.tfvars' >/dev/null; then
  echo "Potential committed secret found." >&2
  exit 1
fi

if grep -RInE \
  --include='*.tf' \
  --include='*.tfvars.example' \
  --include='*.md' \
  '/subscriptions/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' \
  "$ROOT/README.md" "$ROOT/configs" "$ROOT/docs" "$ROOT/infra/tests" |
  grep -v '/subscriptions/00000000-0000-0000-0000-000000000000'; then
  echo "A real Azure subscription resource ID was found in tracked examples or documentation." >&2
  exit 1
fi

for id in $(seq -w 1 17); do
  grep -q "T${id}" "$ROOT/docs/test-matrix.md" || {
    echo "T${id} absent from test matrix." >&2
    exit 1
  }
done

python3 - "$ROOT/docs/checkpoint-cloudguard-byol-architecture.drawio" <<'PY'
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
if root.tag != "mxfile":
    raise SystemExit("draw.io root must be mxfile")
names = [diagram.attrib.get("name") for diagram in root.findall("diagram")]
expected = ["01-现场环境资源与IP", "02-路由与流量", "03-安全策略与TLS", "04-部署与审计"]
if names != expected:
    raise SystemExit(f"unexpected draw.io pages: {names!r}")
for diagram in root.findall("diagram"):
    graph_root = diagram.find("mxGraphModel/root")
    if graph_root is None:
        raise SystemExit(f"diagram {diagram.attrib.get('name')} has no mxGraphModel/root")
    cells = graph_root.findall("mxCell")
    ids = {cell.attrib.get("id") for cell in cells}
    edges = [cell for cell in cells if cell.attrib.get("edge") == "1"]
    for edge in edges:
        for field in ("source", "target"):
            reference = edge.attrib.get(field)
            if reference and reference not in ids:
                raise SystemExit(
                    f"diagram {diagram.attrib.get('name')} edge {edge.attrib.get('id')} "
                    f"has missing {field} {reference}"
                )
    if diagram.attrib.get("name") == "01-现场环境资源与IP":
        if len(edges) > 5:
            raise SystemExit("resource/IP page has too many edges and risks becoming unreadable")
        cells_by_id = {cell.attrib.get("id"): cell for cell in cells}
        x_positions = {
            cell_id: float(cells_by_id[cell_id].find("mxGeometry").attrib["x"])
            for cell_id in ("r-eu-spoke", "r-hub", "r-remote-spoke")
        }
        if not (
            x_positions["r-eu-spoke"]
            < x_positions["r-hub"]
            < x_positions["r-remote-spoke"]
        ):
            raise SystemExit("Hub must be centered between the two spokes")
        peering_pairs = {
            frozenset((edge.attrib.get("source"), edge.attrib.get("target")))
            for edge in edges
            if edge.attrib.get("id", "").startswith("r-e-peer-")
        }
        expected_pairs = {
            frozenset(("r-peer-hub", "r-peer-eu")),
            frozenset(("r-peer-hub", "r-peer-remote")),
        }
        if peering_pairs != expected_pairs:
            raise SystemExit("Spokes must peer independently with Hub and not with each other")
    if diagram.attrib.get("name") == "04-部署与审计" and any(
        edge.attrib.get("source") == "d-s6" or edge.attrib.get("target") == "d-s6"
        for edge in edges
    ):
        raise SystemExit("independent tests must not be connected into the deployment flow")
PY

python3 - "$ROOT/docs/checkpoint-cloudguard-byol-test-architecture.svg" <<'PY'
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
if not root.tag.endswith("svg"):
    raise SystemExit("architecture preview must be an SVG")
if root.attrib.get("viewBox") != "0 0 1600 1000":
    raise SystemExit("architecture preview has an unexpected viewBox")
PY

for script in "$ROOT"/scripts/*.sh "$ROOT"/tests/*.sh; do
  bash -n "$script"
done

"$ROOT/scripts/verify-vendor.sh" >/dev/null

echo "Repository policy checks passed."
