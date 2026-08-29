# 现场验证记录与复查方法

本文记录 2026-08-28 在一个 Azure 学习订阅中的观察结果。区域容量、许可证状态和
Azure Policy 会随订阅与时间变化；这些记录不表示客户环境当前具有相同状态。

## 现场环境

| 角色 | 区域 | VM SKU | 现场条件 |
| --- | --- | --- | --- |
| Check Point `standalone` | North Europe | `Standard_F16s` | 16 vCPU/32 GiB，Marketplace 15 天产品试用 |
| 主工作负载 | North Europe | `Standard_D4ls_v6` | 4 vCPU/8 GiB，无 Public IP |
| 日志收集 VM | North Europe | `Standard_D4ls_v6` | 4 vCPU/8 GiB，`rsyslog` + Azure Monitor Agent |
| 远端工作负载 | West Europe | `Standard_D4ls_v6` | 4 vCPU/8 GiB，无 Public IP |

Marketplace 镜像字段：

```text
publisher = checkpoint
offer     = check-point-cg-r82
plan/sku  = mgmt-byol
```

该订阅在 North Europe 和 West Europe 分配 `Standard_D8s_v5` 时返回
`SkuNotAvailable`。当前 `mgmt-byol` 是 Hyper-V Gen1，不能改用只支持 Gen2
的 Dv6。现场改用 Check Point module 支持且同为 32 GiB 内存的
`Standard_F16s`。这个选择只说明当时的订阅容量，不是长期容量承诺。

## Custom image 与 VHD POC

2026-08-28 使用 Marketplace 版本 `8200.900779.2061` 完成以下验证：

| 项目 | 结果 |
| --- | --- |
| 基础磁盘 | 直接从 Marketplace image 创建，100 GiB、x64、Gen1；从未附加到 VM 或启动 |
| Compute Gallery | `<GALLERY>/<DEFINITION>/<VERSION>`，`Generalized` |
| Purchase plan | 保留 `checkpoint:check-point-cg-r82:mgmt-byol` |
| 副本 | Southeast Asia 和 North Europe 均为 `Completed` |
| 验证 VM | 独立验证 Gateway 从 Gallery version 创建并进入 `Succeeded` |
| CPU 架构 | `x86_64` |
| 新网络身份 | hostname 为验证 VM 名称；`eth0=10.70.0.4/24`、`eth1=10.70.1.4/24` |
| 登录账户 | `admin` SSH key 登录成功；密码状态 `LK`；Azure 占位用户 `notused` 不存在 |
| 主机密钥 | SSH host key 在验证 VM 首次启动时生成 |
| Check Point 密钥 | 检查时有两个 private-key 文件的修改时间属于本次首次启动窗口 |
| VHD | 从未启动的基础磁盘导出为 100 GiB 加密 Page Blob，不是从验证 VM 或已配置 Demo Gateway 导出 |

保留的 POC 资源：

```text
Gallery image:
  <GALLERY>/<DEFINITION>/<VERSION>
Private VHD:
  https://<STORAGE_ACCOUNT>.blob.core.windows.net/vhds/<IMAGE>.vhd
x86 workstation copy:
  /data/cloudguard-images/<IMAGE>.vhd
SHA-256:
  e4eca6aea04d9bd6a450e509cc7a6eaec06ee616cde19f7e9468dbf7db5ef950
```

VHD storage account 禁用 public network 和 shared-key access，通过 x64 runner
VNet 中的 Blob Private Endpoint 访问。本地 VHD 权限是 `0600`。验证结束后 Gateway
与 x64 runner 均已 deallocated；Gallery version、Private Blob、验证 VM 和 runner
数据盘副本保留。

验证 VM 首次启动后存在 Check Point 配置文件、private keys、Azure provisioning
data 和非空日志，这是正常运行状态。这些状态没有进入 Gallery/VHD，因为镜像源是
独立的、从未启动的基础磁盘。

不能把这条结论外推到已配置 VM 的磁盘。Azure specialized image 会保留原机账户、
hostname、主机标识和磁盘中的全部 Check Point 状态；`waagent -deprovision+user`
也不保证清除应用证书、SIC、许可证、策略和日志。因此没有使用现有
`cpbyol-gateway` 作为镜像源。

目标订阅部署 Marketplace 派生 custom image 时仍需要接受原始条款并传入 purchase
plan。若客户限制的是 Marketplace 条款、商务市场或 Azure Policy，这个 custom
image 不能作为绕过手段。跨客户共享前还需要 Check Point 对服务订单/EULA 的书面
确认。

## Custom image 完整端到端验证

2026-08-29 在独立 Resource Group 和独立 Terraform state 中，使用上节的
Generalized Gallery version 部署了完整 standalone Demo。真实 subscription、
Gallery 和 image ID 仅通过运行时环境变量注入，没有写入仓库。

| 检查项 | 结果 |
| --- | --- |
| Terraform image reference | 指向指定 Gallery image version |
| VM purchase plan | `checkpoint:check-point-cg-r82:mgmt-byol` |
| Gaia 首次启动 | `config_system` 完成，FTW 报告 `First time configuration was completed` |
| 新 VM 身份 | 使用新的 VM hostname、两块 NIC 地址、SSH host keys 和 SIC key |
| Management API | Ready，policy 发布和安装成功 |
| HTTPS Inspection | 新 Outbound CA 已安装到两台 workload |
| Log Exporter | `azure-monitor` 为 Running |
| Log Analytics | 出现本次 Gateway 的 Check Point 日志 |
| Continuous Export | 成功创建到未锁定的 immutable container |
| Terraform 收敛 | 创建 export 时完整 plan 仅新增一条 data export rule |

测试矩阵结果：

```text
T01-T02  effective routes                           PASS
T03      cross-region east-west TCP/8080           PASS
T04      allowed HTTPS                             PASS
T05      blocked domain                            PASS
T06      blocked URL path                          PASS
T07      HTTPS Inspection issuer                   PASS
T08      Management API rulebase                   PASS
T09      Log Exporter                              PASS
T10      Log Analytics ingestion                   PASS
T11      Immutability Policy                       PASS
T12      approved Azure regions                    PASS
T13      optional inbound DNAT                      SKIP
```

T13 为预期 `SKIP`，因为 example 默认 `enable_inbound_demo=false`，不是失败。

本次故意强制 `CHECKPOINT_TRANSPORT=run-command` 的首次尝试跨越 Gaia FTW reboot
时，Azure Run Command handler 没有成功安装并留下 stale `Updating`。Guest 中没有
policy 进程，Management API 本身正常。随后使用受 `management_cidr` 限制的 SSH
执行同一幂等 policy 脚本，全部功能测试通过。仓库默认的
`CHECKPOINT_TRANSPORT=auto` 会优先使用 SSH，因此不要为 custom image 强制设为
`run-command`，除非已在目标 image/区域验证该 extension 路径。

## 数据路径观察记录

我执行：

```bash
./scripts/run-tests.sh
```

脚本把原始命令输出写入本地 gitignored 目录：

```text
evidence/20260828T000539Z/
```

| ID | 现场命令或数据源 | 2026-08-28 观察到的字段或行为 |
| --- | --- | --- |
| T01 | Primary NIC effective route table | Active `0.0.0.0/0` → `VirtualAppliance 10.60.1.4` |
| T02 | Remote NIC effective route table | Active `0.0.0.0/0` → `VirtualAppliance 10.60.1.4` |
| T03 | 主工作负载使用 `curl` 访问远端 TCP/8080 | 返回远端演示页面 |
| T04 | `curl https://httpbin.org/anything/allowed` | HTTP 200 |
| T05 | `curl https://example.com/` | 指定域名未返回站点内容 |
| T06 | 对比 httpbin 的 `allowed` 和 `blocked` path | `allowed` 为 200；`blocked` 未返回目标内容 |
| T07 | `openssl s_client` | issuer 为默认 `company_domain`：`example.org` |
| T08 | Management API Access Rulebase | 返回双向 Geo、Application Control、管理和 Gateway service 规则 |
| T09 | `cp_log_export status` | `azure-monitor` 为 `Running` |
| T10 | EU Log Analytics `Syslog` | 出现 Check Point `Accept`、`Drop` 和 policy install 记录 |
| T11 | Azure Immutability Policy API | 365 天、protected append、`Unlocked` |
| T12 | Azure Resource Manager resource locations | 只出现批准的 EU region 或 `global` |
| T13 | 可选 DNAT | `enable_inbound_demo=false`，脚本记录 `SKIP` |

T13 没有参与 active path，因此不能根据这次记录判断入站 DNAT 的行为。

## HTTPS Inspection

我用以下命令检查允许的 HTTPS 请求：

```bash
az vm run-command invoke \
  --subscription <SUBSCRIPTION_ID> \
  --resource-group <RESOURCE_GROUP> \
  --name <PRIMARY_WORKLOAD_VM> \
  --command-id RunShellScript \
  --scripts "curl -4 -v https://httpbin.org/anything/allowed -o /dev/null"
```

证书和 HTTP 状态包含：

```text
subject: CN=httpbin.org
issuer:  CN=example.org
SSL certificate verify ok
HTTP/2 200
```

issuer 表示 Check Point 为该连接签发了叶子证书；HTTP 200 表示演示 CA 已加入
工作负载 trust store，并且允许规则没有阻断该 URL。

## Access Policy

我在 Gateway 上执行 `fw stat`，观察到：

```text
HOST      POLICY
localhost Standard
```

Management API 返回以下规则：

- `CloudGuard Demo - Allow Gateway Services`
- `CloudGuard Demo - Allow Restricted Management SSH`
- `CloudGuard Demo - Block Geo Inbound`
- `CloudGuard Demo - Block Geo Outbound`
- `CloudGuard Demo - Block Domains URLs and Applications`
- `CloudGuard Demo - Allow Inspected East West Web`
- `CloudGuard Demo - Allow Web and DNS Egress`
- `CloudGuard Demo - Cleanup Drop`

`fw stat` 只说明 `Standard` policy 已加载；T03-T07 的流量结果用于检查具体规则行为。

## 日志与不可变存储

我查询 EU Log Analytics `Syslog` 表，观察到以下 Check Point 字段：

```text
action="Accept"
rule_name="CloudGuard Demo - Allow Gateway Services"
src="10.60.1.4"
dst="10.60.2.4"
service="514"
```

Log Analytics Continuous Data Export 显示：

```text
enabled: true
table: Syslog
destination: <EU_STORAGE_ACCOUNT_RESOURCE_ID>
```

Immutability Policy 显示：

```text
state: Unlocked
days: 365
allowProtectedAppendWrites: true
```

现场没有执行 `lock-worm.sh --yes`。`Unlocked` 允许先复查数据导出和保留期，
但不表示容器已经进入不可逆 Locked 状态。

## 部署约束与对应配置

| 现场观察 | 配置中的处理 |
| --- | --- |
| Dv6 只支持 Gen2，R82 `mgmt-byol` 为 Gen1 | 默认使用 `Standard_D8s_v5`；文档列出 `Standard_F16s` 备用规格 |
| SKU catalog 不代表即时容量 | `preflight.sh` 检查 catalog；Azure Compute `apply` 响应决定是否可分配 |
| 并发创建后短时间 GET 返回 404 | 默认 `TF_PARALLELISM=1` |
| Azure Policy 添加 Public IP tag 和 VM identity | 对 policy-owned 字段设置 `ignore_changes` |
| Storage 禁止公网 data-plane | 通过 ARM management-plane template 创建 Storage、container 和 WORM |
| Hub data source 在 plan 中变成 unknown | 使用稳定的 ARM resource ID，避免 Peering 被误替换 |
| Gaia 内置 `jq` 的版本低于管理终端 | 脚本使用 Gaia 版本支持的参数和表达式 |
| Geo Repository 初始为空 | 脚本先运行 `update-updatable-objects-repository-content` |
| 自定义 Application/Site 要求类别 | 设置 `primary-category=Custom_Application_Site` |
| TCP/8080 已有内置 Service | 复用 `HTTP_proxy` |
| Access Layer 默认只启用 Firewall | 设置 `applications-and-url-filtering=true` |
| Gateway 本机日志和 Azure metadata 被默认拒绝 | 增加来源仅为 Gateway object 的服务规则 |
| Anti-Spoofing 要求两块接口 | Gateway object 同时定义 `eth0` External 和 `eth1` Internal |
| Policy 安装后 SSH 需要继续可用 | Azure NSG 和 Check Point policy 使用同一个 `management_cidr` |

## 客户环境需要复查的项目

- 在 Check Point User Center 激活正式 BYOL，并检查 Firewall、Application
  Control、URL Filtering 和 HTTPS Inspection Software Blade。
- 把 `management_cidr` 设置为客户运维出口 `/32`，不使用 `0.0.0.0/0`。
- 在每次部署前重新检查 EU 区域容量、vCPU quota 和 VM SKU。
- 根据客户批准的端点执行 T13，再判断是否启用入站 DNAT。
- 根据合规和成本要求确认保留期；确认后再执行不可逆 WORM lock。
- 生产设计使用 High Availability 或 VMSS、企业 Inspection CA、TLS bypass
  policy、TCP/TLS Log Exporter 和 Storage Private Endpoint。
