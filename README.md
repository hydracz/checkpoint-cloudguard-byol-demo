# Check Point CloudGuard Azure BYOL 独立演示

本目录使用本地保存的 Check Point 官方 Terraform 模块 `v1.3.2`，从
Azure Marketplace 部署 `standalone` CloudGuard。管理服务器、安全网关和
日志服务器运行在同一台 Azure VM 上，Marketplace 计划为 `mgmt-byol`。
许可证不写入 Terraform 配置或状态文件。模块版本、`commit`、许可证和更新方法见
[Terraform 模块本地副本](infra/vendor/README.md)。

这是一个**非生产 Demo**。它用于说明 Azure 路由、Check Point Access Control、
HTTPS Inspection、Geo-IP 和 EU 日志留存如何配合，不提供生产可用性或性能承诺。

## Demo 需求

| 需求 | Demo 中的检查目标 |
| --- | --- |
| L4/L7 流量控制 | 按五元组、Domain、URL 和 Application object 创建 Access Rule；对指定 HTTPS 流量执行解密 |
| 跨境数据控制 | 使用 Check Point Geo Updatable Objects 按国家/地区拒绝入站和出站流量 |
| 南北向和东西向覆盖 | 互联网出站、两个 Azure VNet 之间的跨区域流量都以 `10.60.1.4` 为 NVA 下一跳 |
| 日志审计 | Check Point 日志写入 EU Log Analytics，并持续导出到 EU GRS Storage |
| 防篡改留存 | `am-syslog` 配置 protected append Immutability Policy；客户确认后再执行不可逆锁定 |
| Azure Marketplace BYOL | 使用 `publisher=checkpoint`、R82/R82.10 `offer` 和 `plan=mgmt-byol` |

## 阅读对象与目标

本文面向能阅读 Bash、Terraform 和 Azure CLI 输出的工程师，也供架构师判断
方案边界。读者可以按文档完成以下操作：

1. 在显式指定的 Azure 订阅中部署 Check Point BYOL 演示环境。
2. 解释两块 Gateway NIC、两个 Spoke UDR、Gaia 静态路由和日志路径的分工。
3. 用现场命令检查 L4/L7、Geo-IP、HTTPS Inspection、跨区域流量和 WORM 状态。

## 适用范围与限制

| 项目 | 当前状态 | 会影响什么决定 |
| --- | --- | --- |
| Check Point 拓扑 | 单实例 `standalone` | 适合演示和概念验证（POC）；生产环境需要 High Availability 或 VMSS |
| Check Point 许可 | Azure Marketplace BYOL；现场验证使用 15 天产品试用 | 客户部署前需要准备正式 BYOL，并确认所需 Software Blade 授权功能 |
| Check Point VM | `mgmt-byol` 镜像为 Hyper-V Gen1 | 不能使用只支持 Gen2 的 Dv6；默认选择 `Standard_D8s_v5` |
| Azure VM 容量 | 随订阅、区域和时间变化 | `SkuNotAvailable` 时需要更换区域或兼容规格 |
| 跨区域路径 | Azure Global VNet Peering | 证明私网流量可强制经过防火墙，不代表 ExpressRoute 电路已验证 |
| HTTPS Inspection | 演示 CA | 生产环境需要企业 CA、解密例外、隐私评审和终端证书分发 |
| 日志传输 | `cp_log_export` 使用 UDP/514 | 生产环境需要根据威胁模型评估 TCP/TLS |
| Write Once, Read Many（WORM） | 默认 `Unlocked`，365 天 | 只有执行不可逆锁定后才是 Locked WORM |
| 成本 | Check Point VM、3 台 Linux VM、Public IP、Log Analytics 和 GRS Storage 计费 | 部署前按客户区域和保留期估算费用 |

## 现场验证环境架构

[![Check Point CloudGuard BYOL 现场环境架构](docs/checkpoint-cloudguard-byol-test-architecture.svg)](docs/checkpoint-cloudguard-byol-architecture.drawio)

> 图 1 · 两个工作负载子网的默认路由、对端 Spoke 前缀和 Hub 前缀都指向
> `10.60.1.4`。Azure Global VNet Peering 提供跨区域私网连接，Check Point
> 执行访问控制、HTTPS Inspection 和日志记录。

点击架构图可打开 draw.io 源文件。VM、NIC、用户定义路由（UDR）、Gaia 静态路由、
Azure Global VNet Peering 和网络安全组（NSG）的字段见
[网络与 IP 规划](docs/network-ip-plan.md)。

2026-08-27 的现场环境以 **North Europe** 为主区域：

- Hub VNet `10.60.0.0/16` 包含 Check Point `eth0 10.60.0.4`、
  `eth1 10.60.1.4` 和日志收集 VM `10.60.2.4`。
- 主工作负载 `10.61.0.4` 位于 North Europe；远端工作负载
  `10.62.0.4` 位于 West Europe。
- 两个工作负载的默认路由、对端 Spoke 和 Hub 前缀都指向
  `VirtualAppliance 10.60.1.4`；两个 Spoke 不直接 Peering。
- Check Point 使用 `Standard_F16s`（16 vCPU/32 GiB，作为容量备用规格），
  其余 VM 使用 `Standard_D4ls_v6`（4 vCPU/8 GiB）。
- 日志从 Check Point 发送到 `rsyslog` 收集 VM，再由 Azure Monitor Agent
  写入 EU Log Analytics，最后持续导出到私有 GRS Storage 容器 `am-syslog`。

## 需求覆盖

| 原始要求 | 本演示 |
| --- | --- |
| 五元组、域名、URL、应用、TLS 解密 | Check Point Access Control、Application Control/URL Filtering、HTTPS Inspection Outbound CA 和 Inspect layer。 |
| Geo-IP 跨境阻断 | 脚本从 Check Point Updatable Objects Repository 精确查找并导入国家对象，创建入站和出站 `Drop` 规则。 |
| 南北向和东西向 | 两个 EU 区域的 Spoke 都以 `10.60.1.4` 为默认路由和对端前缀下一跳；可选 DNAT 只接受指定来源 CIDR。 |
| EU 审计和防篡改长期留存 | Check Point Log Exporter → 日志收集 VM/Azure Monitor Agent → EU Log Analytics → 同区域 GRS Storage；`am-syslog` 配置可锁定的 WORM。 |
| Azure Marketplace BYOL | `publisher=checkpoint`、R82/R82.10 `offer`、`plan=mgmt-byol`。 |

需求、配置和证据的对应关系见 [需求与检查条件](REQUIREMENTS.md)、
[技术要求映射](docs/requirement-mapping.md)、[网络与 IP 规划](docs/network-ip-plan.md)、
[现场验证记录](docs/validated-results.md) 和 [draw.io 架构图说明](docs/drawio-architecture.md)。

## 前置条件

- Terraform `>= 1.9`、Azure CLI、`jq`、OpenSSL、Python 3。
- 目标 Azure 订阅的 Contributor 权限，以及接受 Marketplace 条款的权限。订阅的商务市场必须允许购买 Check Point `check-point-cg-r82`/`check-point-cg-r8210` Offer；该 Offer 不向 `CN` 商务市场销售。
- 交互部署默认复用 `az login`；CI 可选使用完整的 Service Principal（tenant/client/secret 三项缺一不可）。
- Check Point BYOL entitlement。若订阅/试用状态不允许安装 Application Control、URL Filtering 或 HTTPS Inspection policy，基础设施仍可部署，但策略安装会明确失败。
- 一个 OpenSSH 公钥和受限的管理公网 CIDR。

> **敏感文件**
>
> 不要提交 client secret、SIC key、私钥、Terraform state 或真实
> `tfvars`。VM bootstrap 参数会进入 Terraform state；生产环境应使用加密、
> 受 RBAC 和锁保护的远程 backend。

## 默认 VM 规格

| 角色 | 默认 SKU | 规格 | 兼容性 |
| --- | --- | --- | --- |
| Check Point standalone | `Standard_D8s_v5` | 8 vCPU / 32 GiB | 当前 `mgmt-byol` image 为 Hyper-V Gen1；使用支持 Gen1 的 Dv5 |
| 主工作负载 | `Standard_D4ls_v6` | 4 vCPU / 8 GiB | Ubuntu 24.04 Gen2 |
| 远端工作负载 | `Standard_D4ls_v6` | 4 vCPU / 8 GiB | Ubuntu 24.04 Gen2 |
| 日志收集 VM | `Standard_D4ls_v6` | 4 vCPU / 8 GiB | Ubuntu 24.04 Gen2 |

Azure Dv6 只支持 Gen2，因此不能把当前 Gen1 Check Point standalone image 放到 `Standard_D8s_v6`。如果 Check Point 后续提供受支持的 Gen2 standalone image，再同步修改 image generation、module 和 SKU。

VM SKU catalog 中存在某个 SKU，不代表当前订阅和区域此刻有容量。若 Azure 在 `apply`
返回 `SkuNotAvailable`，优先换区域；也可使用 Check Point module 支持且保持
32 GiB 内存的 `Standard_F16s`（16 vCPU/32 GiB）。2026-08-27 的现场环境使用
这个备用规格，因为该订阅在 West Europe 和 North Europe 都无法分配
`Standard_D8s_v5`。

## 部署步骤

### 1. 登录并选择客户订阅

```bash
az login
az account list --output table
```

无需修改 Azure CLI 的全局默认订阅。后续脚本对每条 Azure CLI 命令都显式使用 tfvars 中的 `subscription_id`。

### 2. 创建本地参数文件

```bash
cd checkpoint-cloudguard-byol-demo
cp configs/demo.tfvars.example configs/demo.tfvars
```

编辑 `configs/demo.tfvars`：

```hcl
subscription_id     = "<SUBSCRIPTION_ID>"
resource_group_name = "rg-checkpoint-byol-demo"
prefix              = "cpbyol"
company_domain      = "example.org"

location        = "westeurope"
remote_location = "northeurope"

# 当前运维出口公网 IP；禁止 0.0.0.0/0。
management_cidr = "203.0.113.10/32"

checkpoint_vm_size = "Standard_D8s_v5"
workload_vm_size   = "Standard_D4ls_v6"
collector_vm_size  = "Standard_D4ls_v6"
```

### 关键参数

| 参数名 | 是否必填 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- | --- |
| `subscription_id` | 是 | string | 无 | Azure CLI 和 Terraform 明确操作的客户订阅 |
| `management_cidr` | 是 | string | 无 | 允许运维入口的公网 CIDR，不能是 `0.0.0.0/0` |
| `company_domain` | 否 | string | `example.org` | 演示 HTTPS Inspection CA 的 `issued-by`；可填写客户批准的公司域名 |
| `location` | 否 | string | `westeurope` | Hub、Check Point、主工作负载和日志资源所在区域 |
| `remote_location` | 否 | string | `northeurope` | 远端工作负载所在区域，必须与 `location` 不同 |
| `checkpoint_vm_size` | 否 | string | `Standard_D8s_v5` | Check Point VM 规格；受镜像代际和实时容量限制 |
| `workload_vm_size` | 否 | string | `Standard_D4ls_v6` | 两台工作负载 VM 的规格 |
| `collector_vm_size` | 否 | string | `Standard_D4ls_v6` | 日志收集 VM 的规格 |
| `blocked_countries` | 否 | list(string) | `["China"]` | Check Point Repository 中的英文国家名 |
| `enable_tls_inspection` | 否 | bool | `true` | 是否创建演示 CA 和 HTTPS Inspection 规则 |

不同客户只需修改 `tfvars` 中的订阅、网络、命名和策略参数，不需要修改 Terraform 源码。

### 3. 准备 SSH key

```bash
test -f ~/.ssh/id_ed25519.pub || ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519
export TF_VAR_admin_ssh_public_key="$(cat ~/.ssh/id_ed25519.pub)"
```

脚本在未设置变量时也会自动读取 `~/.ssh/id_ed25519.pub`。

Check Point Azure VM 的操作系统 SSH 用户是 `admin`。Azure VM metadata 中可能
显示兼容占位用户名 `notused`，不要用它登录 Gaia。

### 4. 选择认证模式

**本地交互测试（推荐）：**

```bash
unset ARM_TENANT_ID ARM_CLIENT_ID ARM_CLIENT_SECRET
```

Terraform 和 Azure CLI 都使用当前 `az login` 身份，但严格部署到 tfvars 的 `subscription_id`。

**CI / Service Principal：**

```bash
export ARM_TENANT_ID="<TENANT_ID>"
export ARM_CLIENT_ID="<CLIENT_ID>"
export ARM_CLIENT_SECRET="<CLIENT_SECRET>"
```

`subscription_id` 仍写在 `tfvars`；client secret 只通过环境变量传入。

### 5. 只做预检

```bash
./scripts/preflight.sh --var-file configs/demo.tfvars
```

我用这条命令检查以下字段：

- 当前登录身份可以访问 tfvars 指定订阅。
- Check Point Marketplace image 在主区域可用且为预期 Gen1。
- 请求的 SKU 存在于目标区域 VM catalog；即时容量最终由 Terraform apply 的 Azure Compute 响应确认。
- 本地 Terraform module 的 SHA-256 与清单一致。
- `terraform validate` 不应返回配置错误；mock plan tests 应显示 `0 failed`。

### 6. 执行部署

```bash
./scripts/deploy.sh --var-file configs/demo.tfvars
```

脚本先执行预检并接受 `mgmt-byol` Marketplace 条款，再应用基础设施
Terraform plan。Check Point Management API 可用后，脚本写入策略和 Log
Exporter，并把演示 Outbound CA 公钥安装到两台工作负载 VM。

日志导出分为两个 Terraform 阶段。脚本先向日志收集 VM 写入一条 bootstrap
syslog，等待 Log Analytics 创建 `Syslog` 表，再创建 Continuous Data Export。
这一步避免空 workspace 返回 `Table does not exist`。随机 SIC key 只写入权限为
`0600` 的 `.local/deployment-secrets.env`。

策略配置默认 `CHECKPOINT_TRANSPORT=auto`：如果 `management_cidr` 允许当前执行器且
私钥可用，则通过受限 SSH 登录 Gaia `admin`；否则回退到 Azure Run Command。
也可显式设置 `CHECKPOINT_TRANSPORT=ssh` 或 `run-command`。

默认 `TF_PARALLELISM=1`，用于兼容创建后短时间 GET 可能返回 404 的订阅/区域。确认客户订阅控制面稳定后可显式提高，例如 `TF_PARALLELISM=4`。

若 BYOL 必须先在 Gaia/SmartConsole 中激活：

```bash
./scripts/deploy.sh --var-file configs/demo.tfvars --skip-policy
# 完成客户许可证激活后：
./scripts/configure-policy.sh
```

需要同时锁定 WORM 时：

```bash
./scripts/deploy.sh --var-file configs/demo.tfvars --lock-worm
```

> **WORM 锁定**
>
> `--lock-worm` 会让 Storage 在保留期内无法删除，`terraform destroy`
> 也不能绕过。默认状态是 `Unlocked`；先复查日志导出和保留期，再决定是否锁定。

## 检查与运维

### 1. 查看部署输出

```bash
terraform -chdir=infra output
```

我用输出中的以下字段确认目标环境：

- `subscription_id` 是客户目标订阅。
- `checkpoint_backend_private_ip` 是两个工作负载的 NVA 下一跳。
- `checkpoint_management_url` 仅能从 `management_cidr` 访问。
- Log Analytics 和 Storage 位于主 EU region。

### 2. 检查数据路径

```bash
./scripts/run-tests.sh
```

命令把观察结果写入 `evidence/<UTC_TIMESTAMP>/summary.json`：

| 检查 | 应观察到的字段或行为 |
| --- | --- |
| T01/T02 | 两个工作负载 NIC 的 Active `0.0.0.0/0` 都指向 `VirtualAppliance 10.60.1.4` |
| T03 | 跨区域 TCP/8080 返回远端演示页面 |
| T04 | 允许的 HTTPS 请求返回 HTTP 200 |
| T05/T06 | 指定域名和 URL path 被拒绝 |
| T07 | 叶子证书 issuer 为演示 CA，表示 HTTPS Inspection 处理了连接 |
| T08 | Management API 返回双向 Geo 和 Application Control 规则 |
| T09 | `cp_log_export status` 显示 `azure-monitor` 为 `Running` |
| T10 | Log Analytics `Syslog` 表出现 Check Point `Accept`、`Drop` 或 policy install 记录 |
| T11 | Immutability Policy 的保留天数与 Terraform 输出一致 |
| T12 | 资源位置只包含批准的 EU region 或 `global` |
| T13 | 启用 DNAT 时返回主工作负载页面；未启用时记录 `SKIP` |

`SKIP` 表示该功能未启用；`PENDING_INGESTION` 表示 Azure Monitor 尚未完成日志摄取。

### 3. 查询日志

```bash
./scripts/query-logs.sh --hours 2
```

### 4. 确认后锁定 WORM

```bash
./scripts/lock-worm.sh --yes
```

此操作不可逆，锁定后保留期不能缩短，Terraform destroy 在保留期内可能无法删除 Storage。

### 5. 销毁

```bash
CONFIRM_DESTROY="$(terraform -chdir=infra output -raw resource_group_name)" \
  ./scripts/destroy.sh --var-file configs/demo.tfvars
```

检查条件见 [检查矩阵](docs/test-matrix.md)。历史现场输出见
[现场验证记录](docs/validated-results.md)，不代表客户订阅当前状态。

## 常见问题

| 现象 | 原因与处理 |
| --- | --- |
| `ResourcePurchaseValidationFailed` / `not to be sold in market: 'CN'` | 订阅的商务市场不允许购买 Check Point Marketplace Offer；接受条款、切换 Azure 区域或重试均不能解决。改用商务市场受支持且有购买权限的订阅，然后用新订阅 ID 重新部署。 |
| Peering 报 hub VNet `was not found` | 旧版本手工拼接 hub VNet ID，可能未建立正确创建依赖；更新到包含 `vnet_id` 输出的版本后重新运行部署。 |
| `SkuNotAvailable` | VM SKU catalog 存在不代表当前订阅有容量。更换 EU 区域，或在 `checkpoint_vm_size` 使用支持的 32 GiB 备用规格，例如 `Standard_F16s`。 |
| `D8s_v6` 无法部署 Check Point | Dv6 仅支持 Gen2，当前 `standalone` `mgmt-byol` 镜像为 Gen1；使用 `D8s_v5`、`F16s` 或经 Check Point 支持矩阵确认的其他 Gen1 规格。 |
| SSH 用户 `notused` 失败 | Gaia 登录用户是 `admin`；`notused` 只是 Azure metadata 兼容占位。 |
| 重建 VM 后 SSH host key changed | 删除项目专用缓存：`ssh-keygen -R <GATEWAY_PUBLIC_IP> -f .local/known_hosts`，核对 Azure Public IP 后重试。 |
| Azure Run Command 长时间 Updating | 默认 `CHECKPOINT_TRANSPORT=auto` 会优先 SSH；确保 `management_cidr` 是当前执行器 `/32`。 |
| Policy install 报只有一块 interface | Gateway object 必须同时定义 `eth0` External 和 `eth1` Internal。 |
| Updatable Objects repository 未初始化 | 当前脚本会自动执行初始化；首次需要 Check Point 能访问更新服务。 |
| Storage data-plane 403/404 | 审计 Storage/container/WORM 已改为 ARM management-plane template，不要求公网 data-plane。 |

## 官方参考资料

官方链接和第三方许可证集中在 [ATTRIBUTION.md](ATTRIBUTION.md)。
