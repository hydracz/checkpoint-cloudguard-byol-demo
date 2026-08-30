# R81 无 Plan 镜像端到端测试与操作参考

验证时间：2026-08-29 UTC / 2026-08-30 UTC+8

本文是私有镜像目录中 R81 操作记录的可提交副本，记录已实际执行的 Azure Global
发布、完整 Demo 部署、R81/R82 兼容性处理、T01-T16 测试、清理，以及 R81 HTTPS
Inspection 的支持边界。文档只使用占位符；VHD、真实订阅 ID、SAS 和凭据不得提交。

## 1. 已验证镜像

| 字段 | 值 |
| --- | --- |
| 源 | Azure China `checkpoint-cn:cgi-mgmt-r81:mgmt-byol:81.392.710` |
| 归档 | `cloudguard-cn-r81-mgmt-byol-81.392.710.vhd.tar.gz` |
| SHA-256 | `c808277a2a4f30c94510be212f7a76bedd5b320aef61df92189cb2d738f82aef` |
| VHD | fixed、`107374182912` bytes、Hyper-V V1、Linux、Generalized |
| Azure Global definition | `cloudguard-r81-planless` |
| Gallery version | `81.392.710` |
| Purchase plan | `null` |
| 已完成副本 | Southeast Asia、North Europe |
| Guest | Check Point Gaia R81、OS build 392、64-bit |
| Management API | 1.7 |

如果本地私有镜像目录存在，先校验：

```bash
cd cloudguard-images
shasum -a 256 -c MANIFEST.sha256
./process/verify-images.sh
cd ..
```

## 2. 发布到 Azure Compute Gallery

```bash
SUBSCRIPTION_ID="<SUBSCRIPTION_ID>"

./scripts/publish-vhd-image.sh \
  --archive cloudguard-images/r81-no-plan/cloudguard-cn-r81-mgmt-byol-81.392.710.vhd.tar.gz \
  --subscription "$SUBSCRIPTION_ID" \
  --resource-group custom-images \
  --location southeastasia \
  --gallery czgallery \
  --definition cloudguard-r81-planless \
  --version 81.392.710 \
  --checkpoint-release R81 \
  --publisher checkpoint-cn \
  --offer cgi-mgmt-r81 \
  --sku mgmt-byol \
  --target-region northeurope
```

脚本验证 SHA-256、单一 tar member、512-byte alignment、`conectix` footer 和 VHD
disk type `Fixed (2)`；然后通过 Managed Disk Direct Upload 创建临时 managed image
和 Gallery version。再次执行同一命令只校验既有 version、源 SHA 和目标副本。

R81 路径禁止 `--plan-*`。R82/R82.10 路径必须传入对应的 Check Point Marketplace
Plan，不能把有 Plan 镜像伪装为无 Plan。

## 3. 部署参数

创建 gitignored tfvars：

```hcl
subscription_id     = "<SUBSCRIPTION_ID>"
resource_group_name = "rg-checkpoint-r81-e2e"
prefix              = "cpr81"
company_domain      = "example.org"

management_cidr = "<CURRENT_PUBLIC_IPV4>/32"
location        = "northeurope"
remote_location = "westeurope"

checkpoint_os_version          = "R81"
checkpoint_image_id            = "/subscriptions/<SUBSCRIPTION_ID>/resourceGroups/custom-images/providers/Microsoft.Compute/galleries/czgallery/images/cloudguard-r81-planless/versions/81.392.710"
checkpoint_image_requires_plan = false
checkpoint_vm_size             = "Standard_F16s"

workload_vm_size  = "Standard_D4ls_v6"
collector_vm_size = "Standard_D4ls_v6"

# R81 GA/API 1.7 cannot bootstrap HTTPS Inspection headlessly.
enable_tls_inspection = false
```

部署：

```bash
export TERRAFORM="<PATH_TO_TERRAFORM_1_9_OR_NEWER>"
export TF_VAR_admin_ssh_public_key="$(tr -d '\r\n' < ~/.ssh/id_ed25519.pub)"

# Only use this opt-in if an organization policy removes the /32 SSH rule.
export CHECKPOINT_RECONCILE_SSH_RULE=true

./scripts/deploy.sh --var-file "<R81_TFVARS>"
```

R81 first boot 中 SSH 可能先于 Management API 和 Log Exporter 可用。脚本等待
`mgmt_cli` 登录和 `cp_log_export` 均就绪后才配置策略。临时恢复的 SSH rule 只允许
`management_cidr` 到 TCP/22，并在命令结束时删除，避免 Terraform state 冲突。

## 4. R81 兼容性处理

| R81 差异 | 当前处理 |
| --- | --- |
| VM 不携带 Azure Plan | `checkpoint_image_requires_plan=false`，VM `plan=null` |
| 模块原本不接受 `R81`/`cgi-mgmt-r81` | vendored module 只为无 Plan R81 扩展校验 |
| 不支持 `nat-hide-internal-interfaces` | 显式东西向 No-NAT + 公网 Hide NAT |
| NAT rulebase 不稳定返回 rule name | 用已知 rule name 做 show/delete |
| Gaia 内置旧 `jq` | 转换类型后匹配，不使用其不支持的输出格式 |
| custom URL 普通 pattern 行为不同 | R81 使用转义 regex；纯域名增加 DNS Domain Drop |
| API 1.7 无 Outbound CA/Gateway HTTPS 写接口 | 默认关闭 TLS，或使用第 7 节 SmartConsole 混合模式 |

## 5. 完整测试结果

最终自动矩阵证据目录：

```text
evidence/20260829T211512Z/
```

| ID | 结果 | 说明 |
| --- | --- | --- |
| T01 | PASS | 主 workload 默认路由指向 NVA |
| T02 | PASS | 远端 workload 默认路由指向 NVA |
| T03 | PASS | 跨区域 TCP/8080 |
| T04 | PASS | 允许 HTTPS |
| T05 | PASS | 域名阻断 |
| T06 | PASS | R81 HTTP URL path 阻断 |
| T07 | SKIP | R81 GA/API 1.7 未完成 SmartConsole TLS bootstrap |
| T08 | PASS | Geo/L7 rulebase |
| T09 | PASS | Log Exporter Running |
| T10 | PASS | Log Analytics 摄取 |
| T11 | PASS | 365 天 Immutability Policy |
| T12 | PASS | 资源只在批准 EU region/global |
| T13 | PASS | 严格限源 TCP/18080 DNAT |
| T14 | PASS | 精确 image version、VM `plan=null` |
| T15 | PASS | Guest 为 Gaia R81 |
| T16 | PASS | 东西向保留原 workload 源 IP |

结果为 **15 PASS / 1 SKIP**。T07 没有伪装成 PASS。

运行：

```bash
export CHECKPOINT_RECONCILE_SSH_RULE=true
./scripts/run-tests.sh
```

## 6. T13 入站 DNAT

只从当前批准出口测试：

```hcl
enable_inbound_demo      = true
inbound_demo_source_cidr = "<CURRENT_PUBLIC_IPV4>/32"
```

重新 apply 和安装 policy：

```bash
./scripts/plan.sh --var-file "<R81_TFVARS>"
terraform -chdir=infra apply \
  -input=false -auto-approve \
  "$(pwd)/.local/plan.tfplan"

CHECKPOINT_RECONCILE_SSH_RULE=true ./scripts/configure-policy.sh
./scripts/run-tests.sh
```

直接复查：

```bash
curl -fsS "http://<GATEWAY_PUBLIC_IP>:18080/"
```

预期返回主 workload 页面。可选入站 allow 是 Geo Inbound 前的窄例外，必须同时命中
Azure NSG 和 Check Point Policy 中相同的 `/32`，且只开放 TCP/18080。其他来自
`blocked_countries` 的入站流量继续被 Geo rule 拒绝。

测试后把 `enable_inbound_demo=false`，重新 apply 和安装 policy，移除公网入口。

## 7. R81 HTTPS Inspection：支持的非 API 路径

### 结论

R81 GA 映射到 Management API 1.7。现场 schema 不包含：

- `add/import/show/set-outbound-inspection-certificate`
- Gateway `enable-https-inspection`

R81 Jumbo 只把 API 提升到 1.7.1，不能补齐这些接口。厂商支持的 R81 GA 路径是
**SmartConsole 人工 bootstrap**；没有验证到受支持的纯 headless CLI 路径。

不要使用猜测的 `dbedit` 字段、`set generic-object`、私有 SmartConsole endpoint、
直接修改 `objects_5_0.C` 或 UI automation。这些方式不应作为成功测试证据。

### SmartConsole bootstrap

使用与 R81 匹配的 SmartConsole，并从 `management_cidr` 连接 standalone Management：

1. **Gateways & Servers** → 编辑 standalone Gateway → **HTTPS Inspection**。
2. Step 1 选择：
   - **Create**：填写 Issued by (DN)、私钥密码、有效期；或
   - **Import**：导入包含私钥的客户 CA/P12 并输入密码。
3. 使用 **Export certificate** 导出只含公钥的客户端 trust certificate。
4. Step 3 选择 **Enable HTTPS Inspection**。
5. **Menu → Manage policies and layers**，编辑 package，启用
   **Access Control & HTTPS Inspection**。
6. 在 HTTPS Inspection rulebase 中先添加必要 Bypass，再添加 outbound Inspect rule：
   - Source：受保护网络
   - Destination：Internet
   - Service：HTTPS
   - Action：Inspect
   - Certificate：Outbound Certificate
   - Track：Log
   - Install On：standalone Gateway
7. Publish 并 Install Access Control policy。

### 让仓库继续安装 CA trust 并执行 T07

完成 SmartConsole 配置后，把 tfvars 改为：

```hcl
enable_tls_inspection       = true
r81_tls_manually_configured = true
```

然后：

```bash
export CHECKPOINT_TLS_CA_FILE="<SMARTCONSOLE_EXPORTED_PUBLIC_CA>"
export CHECKPOINT_RECONCILE_SSH_RULE=true

./scripts/plan.sh --var-file "<R81_TFVARS>"
terraform -chdir=infra apply \
  -input=false -auto-approve \
  "$(pwd)/.local/plan.tfplan"
./scripts/configure-policy.sh
./scripts/run-tests.sh
```

`configure-policy.sh` 接受 PEM 或 DER X.509 公钥证书，安装到两台 workload；R81 policy
脚本保留 SmartConsole 管理的 CA、Gateway HTTPS setting、layer 和 Inspect rule。
T07 从该 CA 的 RFC2253 subject 推导期望 issuer，必须与实际被拦截连接的 leaf
certificate issuer 匹配才算 PASS；导入企业 CA 时不强制其 subject 等于
`company_domain`。

R81 的 `$FWDIR/bin/export_https_cert -local -f <file>` 是 Management Server 之间迁移
加密 CA/private-key package 的命令，不是客户端 public trust export，不能代替
SmartConsole 的 **Export certificate**。

### 可自动化升级选项

- R81.20/API 1.9：支持导入外部 P12、启用 Gateway HTTPS Inspection 和 generic HTTPS
  layer；自动化必须另外保留/分发该 P12 的 public certificate。
- R82/API 2：支持完整 outbound CA API、显式 inbound/outbound layers 和
  `base64-public-certificate`，是完整 headless 流程的首选。

R81 → R81.20 是支持的 standalone 直接升级路径，但升级前必须完成 backup、
Pre-Upgrade Verifier、磁盘空间检查、关闭 SmartConsole sessions，并按 CPUSE 官方流程
执行；不要把升级混入镜像发布脚本。

## 8. 清理与保留

验证结束后的状态：

- 4 台 Demo VM deallocated。
- upload Managed Disk 和临时 managed image 已删除。
- Gallery definition/version 及 Southeast Asia、North Europe 副本保留。
- WORM policy 为 `Unlocked`，未执行不可逆 lock。

重新 deallocate：

```bash
for VM in cpr81-gateway cpr81-eu-workload cpr81-remote-workload cpr81-log-collector; do
  az vm deallocate \
    --subscription "<SUBSCRIPTION_ID>" \
    --resource-group rg-checkpoint-r81-e2e \
    --name "$VM" \
    --no-wait
done
```

## 9. 官方参考

- R81 HTTPS Inspection：
  <https://sc1.checkpoint.com/documents/R81/WebAdminGuides/EN/CP_R81_SecurityManagement_AdminGuide/Topics-SECMG/HTTPS-Inspection.htm>
- Management API version matrix：
  <https://sc1.checkpoint.com/documents/latest/APIs/data/v2/api_versions.html>
- API 1.9 changes：
  <https://sc1.checkpoint.com/documents/latest/APIs/data/v1.9/dynamic/changes.json>
- API 2 changes：
  <https://sc1.checkpoint.com/documents/latest/APIs/data/v2/dynamic/changes.json>
- R81 `dbedit` warning：
  <https://sc1.checkpoint.com/documents/R81/WebAdminGuides/EN/CP_R81_SecurityManagement_AdminGuide/Topics-SECMG/CLI/dbedit.htm>
- R81.20 supported upgrade paths：
  <https://sc1.checkpoint.com/documents/R81.20/WebAdminGuides/EN/CP_R81.20_RN/Content/Topics-RN/Supported-Upgrade-Paths.htm>
- R81.20 CPUSE upgrade：
  <https://sc1.checkpoint.com/documents/R81.20/WebAdminGuides/EN/CP_R81.20_Installation_and_Upgrade_Guide/Content/Topics-IUG/Upgrading-Mmgt-Server-or-Log-Server-from-R80_20-and-higher-with-CPUSE.htm>
