# 现场验证记录与复查方法

本文记录 2026-08-28 到 2026-08-29 UTC（UTC+8 为 2026-08-30）在一个 Azure
学习订阅中的观察结果。区域容量、许可证状态和 Azure Policy 会随订阅与时间变化；
这些记录不表示客户环境当前具有相同状态。

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

## R81 无 Plan VHD 完整端到端验证

2026-08-29 UTC 使用本地 R81 固定 VHD 归档重新执行“上传 → Gallery image →
完整 Demo 部署 → 策略/流量/日志测试”。真实 subscription 和资源 ID 没有写入仓库。

### 镜像发布

| 项目 | 实测结果 |
| --- | --- |
| 源归档 | 单一固定 VHD，`107374182912` bytes，`conectix` footer |
| 归档 SHA-256 | `c808277a2a4f30c94510be212f7a76bedd5b320aef61df92189cb2d738f82aef` |
| Direct Upload | AzCopy 传输 `107374182912` bytes，1/1 完成 |
| Gallery version | `cloudguard-r81-planless/81.392.710` |
| Definition | Linux、Generalized、x64、Hyper-V V1、`purchasePlan=null` |
| 副本 | Southeast Asia 和 North Europe 均为 `Completed` |
| 可重复执行 | 再次运行发布脚本只校验 SHA、metadata 和目标副本并返回既有 version |

发布脚本给 definition/version 写入 `checkpoint-release=R81` 和
`marketplace-plan-required=false` 标签。R82 有 Plan definition 同时保留在同一
Gallery；两个 definition 可并存。

### 部署与 Guest 验证

| 检查项 | 实测结果 |
| --- | --- |
| VM image reference | 精确 version `81.392.710` |
| VM purchase plan | `null` |
| VM SKU | `Standard_F16s`，Gen1，16 vCPU/32 GiB |
| Gaia | Check Point Gaia R81，OS build 392，64-bit |
| Management API | 1.7 |
| 首次启动 | `config_system` 完成并重启，之后 Management API Ready |
| 策略 | L4、Application Control、URL Filtering、双向 Geo、东西向 No-NAT 和公网 Hide NAT 安装成功 |
| 审计 | Log Exporter Running、Log Analytics 摄取、Continuous Export 和 365 天未锁定 Immutability Policy 均成功 |
| Terraform 收敛 | 审计 export 创建后，无业务基础设施变更 |

R81 首次启动时 SSH 已可连接但 `config_system` 仍在安装 Management/Log Exporter
组件。脚本现在同时等待 SSH、Management API 和 `cp_log_export`，避免把“端口已开”
误判为“产品已就绪”。

R81 与 R82 的公开 API 能力并不完全相同，现场发现并修复了以下差异：

| R81 差异 | 脚本处理 |
| --- | --- |
| 不支持 `nat-hide-internal-interfaces` | 使用跨版本的显式东西向 No-NAT + 公网 Hide NAT rules |
| NAT rulebase 响应省略 rule name | 按已知 rule name 调用 `show/delete nat-rule`，保证幂等 |
| Gaia 内置旧 `jq` 对非字符串 `startswith` 会退出 | 先转成字符串；不依赖 R81 不支持的 `@tsv` |
| 普通 custom URL pattern 未按 R82 方式命中 | R81 使用转义正则；纯域名另建 DNS Domain Drop rule |
| API 1.7 无 Outbound Inspection CA/Gateway HTTPS Inspection 写接口 | R81 自动化要求关闭 TLS；不使用未支持的 `dbedit` 或私有 API |
| 订阅自动删除 `/32` SSH NSG rule | 客户确认后可显式启用 `CHECKPOINT_RECONCILE_SSH_RULE=true` 恢复同一受限 rule |

### 测试矩阵

最终证据目录：`evidence/20260829T183504Z/`（gitignored）。

```text
T01-T02  effective routes                           PASS
T03      cross-region east-west TCP/8080           PASS
T04      allowed HTTPS                             PASS
T05      blocked domain                            PASS
T06      blocked HTTP URL path                     PASS
T07      HTTPS Inspection issuer                   SKIP
T08      Management API rulebase                   PASS
T09      Log Exporter                              PASS
T10      Log Analytics ingestion                   PASS
T11      Immutability Policy                       PASS
T12      approved Azure regions                    PASS
T13      optional inbound DNAT                     SKIP
T14      exact image reference and null Plan       PASS
T15      Gaia release                              PASS
T16      east-west source IP preservation          PASS
```

T13 仍因默认 `enable_inbound_demo=false` 而跳过。T07 是 R81 的明确产品/API
边界，不是误报为成功：R81 GA Management API 1.7 无法用仓库支持的公开接口创建
Outbound Inspection CA 或启用 Gateway HTTPS Inspection。关闭 TLS 时，T06 改用
HTTP path 继续验证 URL Filtering。需要自动执行并验证 TLS 解密时，继续使用已验证的
R82/R82.10 路径。

最终结论是：镜像发布、Plan 选择、首次启动、L4/L7（不含 R81 自动 TLS 解密）、
Geo、跨区域路由、日志和 WORM 脚本均可按版本适配；R81 与 R82 **不是完整功能等价**。
两条 preflight 均通过，Terraform mock/full-module 测试为 `10 passed, 0 failed`。
最终矩阵为 14 项 `PASS`、2 项预期 `SKIP`；T16 在远端 workload journal 中观察到
原始主 workload IP，确认东西向流量没有被公网 Hide NAT 改写。

测试完成后，4 台 R81 Demo VM 均已 deallocated；Direct Upload 的临时 managed
image 和 upload disk 已删除。R81 Gallery version 及其两个已完成副本保留，便于后续
重复部署。WORM policy 仍为 `Unlocked`，未执行不可逆锁定。

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
