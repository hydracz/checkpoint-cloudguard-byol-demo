# VM、网卡、路由与 IP 规划

本文说明 draw.io 第一、二页使用的字段。Terraform 变量是配置依据。除明确标注
“现场”的内容外，下表使用 `configs/demo.tfvars.example` 的默认值；资源名前缀
可通过 `prefix` 修改。

## 区域和地址空间

| 层级 | 默认区域 | 地址空间 | 用途 |
| --- | --- | --- | --- |
| Hub VNet | West Europe | `10.60.0.0/16` | Check Point 三网卡、日志收集 VM、Windows 管理工作站和 Azure Bastion |
| Frontend subnet | West Europe | `10.60.0.0/24` | Check Point `eth1` / External / Public IP |
| Backend subnet | West Europe | `10.60.1.0/24` | Check Point `eth2` / Internal / NVA next hop |
| Collector subnet | West Europe | `10.60.2.0/24` | rsyslog + Azure Monitor Agent |
| Management subnet | West Europe | `10.60.3.0/24` | Check Point `eth0` + 私有 Windows Server / SmartConsole |
| `AzureBastionSubnet` | West Europe | `10.60.4.0/26` | Basic Azure Bastion 专用子网 |
| EU Spoke VNet | West Europe | `10.61.0.0/16` | 主工作负载 |
| EU workload subnet | West Europe | `10.61.0.0/24` | 主工作负载 NIC |
| Remote Spoke VNet | North Europe | `10.62.0.0/16` | 远端工作负载 |
| Remote workload subnet | North Europe | `10.62.0.0/24` | 远端工作负载 NIC |

`location` 和 `remote_location` 必须是不同的批准 EU 区域。

## VM 和 NIC 清单

| 角色 | Azure 资源名（默认） | SKU / OS | NIC | 私网 IP | Public IP | IP forwarding |
| --- | --- | --- | --- | --- | --- | --- |
| Check Point standalone | `cpbyol-gateway` | `Standard_D8s_v5`（8C/32GiB）/ Check Point R82 | `cpbyol-gateway-management` | `10.60.3.4` | 无；私网管理 | Disabled |
| Check Point standalone | 同一 VM | 同上 | `cpbyol-gateway-frontend` | `10.60.0.4` | Standard Static，用于出站 NAT 和可选 DNAT；不开放管理端口 | Enabled |
| Check Point standalone | 同一 VM | 同上 | `cpbyol-gateway-backend` | `10.60.1.4` | 无 | Enabled |
| 主工作负载 | `cpbyol-eu-workload` | `Standard_D4ls_v6`（4 vCPU/8 GiB）/ Ubuntu 24.04 | `cpbyol-eu-workload-nic` | `10.61.0.4` | 无 | Disabled |
| 远端工作负载 | `cpbyol-remote-workload` | `Standard_D4ls_v6`（4 vCPU/8 GiB）/ Ubuntu 24.04 | `cpbyol-remote-workload-nic` | `10.62.0.4` | 无 | Disabled |
| 日志收集 VM | `cpbyol-log-collector` | `Standard_D4ls_v6`（4 vCPU/8 GiB）/ Ubuntu 24.04 | `cpbyol-collector-nic` | `10.60.2.4` | Standard Static，只用于 Azure Agent 初始出站；NSG 不开放公网管理 | Disabled |
| Windows 管理工作站 | `cpbyol-windows-client` | `Standard_D4ls_v6`（4 vCPU/8 GiB）/ Windows Server 2022 Azure Edition | `cpbyol-windows-client-nic` | `10.60.3.10` | 无；只通过 Azure Bastion RDP | Disabled |

> **VM 代际**
>
> Dv6 只支持 Hyper-V Gen2，当前 Check Point R82 `mgmt-byol`
> Marketplace image 是 Gen1。因此 Check Point 默认使用 8 vCPU/32 GiB 的
> `Standard_D8s_v5`；Ubuntu 工作负载和日志收集 VM 使用 Gen2
> `Standard_D4ls_v6`。

若目标订阅返回 `SkuNotAvailable`，先更换 EU 主区域。2026-08-27 的现场环境
使用 Check Point module 支持的 `Standard_F16s`（16 vCPU/32 GiB）作为备用规格。
SKU catalog 查询不能保证即时容量。

## Check Point 网卡角色

| Gaia 接口 | Azure NIC | Topology | 地址 | 功能 |
| --- | --- | --- | --- | --- |
| `eth0` | `cpbyol-gateway-management` | Management | `10.60.3.4/24` | Azure primary NIC；Gaia Portal、SSH、SmartConsole；仅私网 |
| `eth1` | `cpbyol-gateway-frontend` | External | `10.60.0.4/24` | Azure Public IP NAT、互联网出站和可选 DNAT |
| `eth2` | `cpbyol-gateway-backend` | Internal | `10.60.1.4/24` | 所有工作负载 UDR 的下一跳、东西向流量和返回路径 |

`eth2` Anti-Spoofing topology 使用 Management API 枚举值
`network defined by routing`。Gaia 静态路由因此需要包含两个 Spoke 和日志收集子网。

## Azure 用户定义路由

### 主工作负载 Route Table

资源名：`cpbyol-eu-workload-rt`。默认开启管理工作站/Bastion 时共 **12 条**：

| 路由名 | Prefix | Next hop type | Next hop IP | 目的 |
| --- | --- | --- | --- | --- |
| `default-via-checkpoint` | `0.0.0.0/0` | `VirtualAppliance` | `10.60.1.4` | 所有互联网出站经 Check Point |
| `remote-spoke-via-checkpoint` | `10.62.0.0/16` | `VirtualAppliance` | `10.60.1.4` | 主工作负载 → 远端工作负载 |
| `hub-inspect-10-60-0-0-22` | `10.60.0.0/22` | `VirtualAppliance` | `10.60.1.4` | Hub 补集：frontend/backend/collector/management |
| `hub-inspect-10-60-4-64-26` | `10.60.4.64/26` | `VirtualAppliance` | `10.60.1.4` | Hub 补集 |
| `hub-inspect-10-60-4-128-25` | `10.60.4.128/25` | `VirtualAppliance` | `10.60.1.4` | Hub 补集 |
| `hub-inspect-10-60-5-0-24` | `10.60.5.0/24` | `VirtualAppliance` | `10.60.1.4` | Hub 补集 |
| `hub-inspect-10-60-6-0-23` | `10.60.6.0/23` | `VirtualAppliance` | `10.60.1.4` | Hub 补集 |
| `hub-inspect-10-60-8-0-21` | `10.60.8.0/21` | `VirtualAppliance` | `10.60.1.4` | Hub 补集 |
| `hub-inspect-10-60-16-0-20` | `10.60.16.0/20` | `VirtualAppliance` | `10.60.1.4` | Hub 补集 |
| `hub-inspect-10-60-32-0-19` | `10.60.32.0/19` | `VirtualAppliance` | `10.60.1.4` | Hub 补集 |
| `hub-inspect-10-60-64-0-18` | `10.60.64.0/18` | `VirtualAppliance` | `10.60.1.4` | Hub 补集 |
| `hub-inspect-10-60-128-0-17` | `10.60.128.0/17` | `VirtualAppliance` | `10.60.1.4` | Hub 补集 |

这些 Hub UDR 精确覆盖 `10.60.0.0/16` 减去 `10.60.4.0/26`：65,472 个地址继续受检，
只有 Bastion 子网的 64 个地址不匹配 Hub UDR。返回 Bastion 的包使用系统 Hub Peering
`/16`，优先于 NVA 默认 `/0`。**不创建到 Bastion 的 `/26` UDR**，也不保留主表旧
`hub-via-checkpoint /16`；Azure UDR 的 next hop 不能填写 `Virtual network peering`。

`infra/routing.tf` 根据 `hub_address_space` 和 `bastion_subnet_prefix` 计算补集；
路由数随前缀长度变化。二者必须为规范 IPv4 CIDR，Bastion 固定 `/26`，开启时必须严格位于
Hub 内。关闭 `enable_management_workstation` 后，主表只保留默认、对端和原
`hub-via-checkpoint` 三条，不再排除未部署的 Bastion 子网。

### 远端工作负载 Route Table

资源名：`cpbyol-remote-workload-rt`，仍为原来的 **3 条**；本次不改变远端回程策略，
也不宣称远端 workload 的 Bastion 直连已经可用。

| 路由名 | Prefix | Next hop type | Next hop IP | 目的 |
| --- | --- | --- | --- | --- |
| `default-via-checkpoint` | `0.0.0.0/0` | `VirtualAppliance` | `10.60.1.4` | 所有互联网出站经 Check Point |
| `eu-spoke-via-checkpoint` | `10.61.0.0/16` | `VirtualAppliance` | `10.60.1.4` | 远端工作负载 → 主工作负载 |
| `hub-via-checkpoint` | `10.60.0.0/16` | `VirtualAppliance` | `10.60.1.4` | 远端工作负载访问 Hub 时仍经过 Check Point |

BGP route propagation 在两个工作负载 Route Table 上关闭，避免未来专线路由在
未评审时覆盖演示 UDR。

### Bastion 回程修正与迁移

旧主表的 Hub `/16` UDR 会让 `Bastion → 主 workload` 去程直接走 Peering、回程却进入
NVA。这是需要修正的非对称设计；具体丢包点仍需结合有效路由、NSG 和连接诊断判断。
本方案只改**主 workload 的路由表**，不改 Bastion 子网、远端表、Gateway 的两张表，
也不改 Gaia 默认路由。

在 Portal 手工迁移旧主表时按以下顺序操作；**已完成相同修正的环境不要重复增删**：

1. 打开主 workload → Networking → NIC → Subnet，确认关联的是
   `cpbyol-eu-workload-rt`；保存现有三条路由和关联信息。
2. 打开该 Route Table → **Routes → Add**，逐条添加上表 10 条 `hub-inspect-*`。
   Next hop type 均为 **Virtual appliance**，Next hop address 均为 **`10.60.1.4`**。
   暂时保留旧 `hub-via-checkpoint`，此时表内应为 13 条。
3. 确认 10 条的名称、前缀和下一跳全部正确后，删除旧
   **`hub-via-checkpoint` / `10.60.0.0/16`**，最终 12 条；保留默认和对端路由。
4. 在 workload NIC 的 **Effective routes** 中确认 Bastion 地址的最长匹配是系统
   Peering，不是 NVA；Hub 其余地址、默认出站和对端 Spoke 仍按表受检。
   在 Bastion 的 **Connection troubleshoot** 中检查目标 `10.61.0.4`、TCP/22，
   再用匹配的 SSH 凭据实际登录。`Reachable` 仅证明 TCP，不证明认证或全部安全策略。
5. 如需回滚，**先恢复**旧 `hub-via-checkpoint 10.60.0.0/16 → VirtualAppliance 10.60.1.4`，
   再删除本次 10 条；默认、对端路由和子网关联始终保留。回滚会恢复旧 Bastion 回程问题。

不要只把旧 Hub `/16` 改成 `/22`，否则会放过 Bastion 以外的 Hub 地址；不要给
`AzureBastionSubnet` 绑定 UDR，也不要尝试用跨 VNet 的 `VnetLocal /26` 代替 Peering。
Gateway frontend/backend 路由表由 vendored Check Point 模块创建，其 `To-Internal`、
`Local-Subnet`、`To-Internet` 等路由不属于此次迁移。

**与 Terraform 对齐：** 在持有原 state 和 tfvars 的部署目录更新代码后审查
`./scripts/plan.sh --var-file configs/demo.tfvars`。已经通过 Portal 修正且 CIDR 相同的环境，
计划不应再恢复主表旧 Hub `/16`。现有表仍由原 `azurerm_route_table.eu_workload` 的 inline
routes 管理，不要额外导入独立 `azurerm_route`；也不要用空 state 对现有环境重新部署。
此次路由修正本身不要求替换 VM、NIC 或 Peering，若计划包含这些变更应停止并单独评审。
本文的增删顺序针对手工迁移，不承诺一次 Terraform apply 的逐条路由更新顺序。

例外依据目标子网对所有协议生效，并不是 Bastion-only SSH 访问控制。Ubuntu 密钥认证、
NSG 和 guest firewall 保持原状；密码启用、收紧 SSH 来源和清理手工临时公网 IP 均需另行批准，
不能与本次路由更改混为一谈。

## Gaia 静态路由

Azure UDR 只把包送入 NVA，不会修改 Check Point Gaia 路由表。默认部署后，管理员
在 Gaia Portal 手工创建以下静态路由；保留的 `checkpoint-policy.sh` 也可从私网执行：

| Destination | Next hop | Egress | 目的 |
| --- | --- | --- | --- |
| `0.0.0.0/0` | `10.60.0.1` | `eth1` | Gateway 与检查后公网流量从 frontend 发出 |
| `10.61.0.0/16` | `10.60.1.1` | `eth2` | 返回 EU Spoke |
| `10.62.0.0/16` | `10.60.1.1` | `eth2` | 返回 Remote Spoke |
| `10.60.2.0/24` | `10.60.1.1` | `eth2` | Log Exporter 到日志收集 VM |

`10.60.1.1` 是 backend subnet 的 Azure 虚拟网关地址。

## Peering

| 本地 VNet | 远端 VNet | 类型 | `allow_forwarded_traffic` | 说明 |
| --- | --- | --- | --- | --- |
| Hub | EU Spoke | VNet Peering | `true` | 双向各一条 Peering resource |
| Hub | Remote Spoke | Azure Global VNet Peering | `true` | 双向各一条 Peering resource |
| EU Spoke | Remote Spoke | **无直接 Peering** | N/A | 防止系统路由绕过 Check Point |

生产接入 ExpressRoute、Virtual WAN 或 VPN 时，需要把远端前缀加入工作负载
UDR、Gaia 静态路由和 Anti-Spoofing 配置。

## NSG 摘要

### Check Point frontend/backend 共用 NSG

| 优先级 | 来源 | 协议/端口 | 目的 |
| --- | --- | --- | --- |
| 500 | `10.61.0.0/16` | `Any` | 主 Spoke 转发流量 |
| 510 | `10.62.0.0/16` | `Any` | 远端 Spoke 转发流量 |
| 520（条件化） | `inbound_demo_source_cidr` | TCP/18080 | 可选 DNAT 演示 |

该 NSG 不包含从 Internet/Public CIDR 到 TCP/22、443、18190 或 19009 的 allow rule；
frontend Public IP 无法进入 Gaia/SmartConsole。可选 DNAT 来源仍拒绝 `0.0.0.0/0`。

### Check Point management NIC NSG

| 优先级 | 来源 | 协议/端口 | 目的 |
| --- | --- | --- | --- |
| 100-103 | `management_subnet_prefix` + `management_cidrs` | TCP/22、443、18190、19009 | SSH、Gaia Portal、SmartConsole |
| 200 | 其他 `VirtualNetwork` 来源 | Any | 显式拒绝非管理网络 |

`management_cidrs` 默认为空，且拒绝 `0.0.0.0/0`；`10.60.3.0/24` 始终自动加入。
NSG 绑定 Gateway `eth0` NIC，不绑定 frontend/backend subnet。
如果追加 VPN/运维网段，手工 Gaia 配置或保留脚本还会为每个额外 CIDR 创建经
`10.60.3.1` / `eth0` 的返回路由，避免响应误走 frontend 默认路由。

### Workload NSG

- EU 和 Remote 分别使用同区域 NSG，避免跨区域 NSG 关联失败。
- TCP/8080 只允许 Hub、EU Spoke 和 Remote Spoke。
- 启用 DNAT 时，主工作负载 NSG 额外允许 `inbound_demo_source_cidr`，因为 Check Point 保留原始来源 IP。
- SSH 使用现有默认 `AllowVnetInBound` 和 guest 配置；本次不新增 Any/Internet SSH Allow，
  也不把 NSG 改成 Bastion-only。若现场有额外 Deny，需按实际优先级单独诊断。

### Collector NSG

- UDP/514：只允许 `10.60.1.4/32`。
- TCP/514：只允许 `10.60.1.4/32`，为后续切换 TCP/TLS 预留。
- 不开放公网 SSH；日志收集 VM 的 Public IP 只提供 Azure Agent/extension 初始出站能力。

### Windows 管理工作站 NSG

- TCP/3389 只允许 `10.60.4.0/26`（`AzureBastionSubnet`）。
- 优先级 110 拒绝其他 `VirtualNetwork` 主动入站；已建立连接的返回流量仍由 NSG
  stateful 规则允许。
- Windows NIC 不绑定 Public IP；Bastion subnet 不复用工作站 NSG。

## 数据面逐包路径

### 主 Spoke 的 Bastion 管理路径

```text
Bastion 10.60.4.0/26 -> Hub/EU Spoke peering -> EU VM 10.61.0.4:22
EU VM -> system Hub peering route 10.60.0.0/16 -> Bastion
```

这条路径不经过 CloudGuard，也不通过 Windows 中转。Windows `10.60.3.10` 不在例外内，
主 workload 到 Windows 等其他 Hub 地址仍命中 NVA UDR。

### 互联网出站

```text
EU/Remote VM
  -> 工作负载 UDR 0/0
  -> Check Point eth2 10.60.1.4
  -> Access Control + Geo + Application/URL + HTTPS Inspection
  -> Check Point eth1 10.60.0.4
  -> Azure Public IP NAT
  -> Internet
```

### 跨区域东西向

```text
EU VM 10.61.0.4
  -> EU UDR 10.62.0.0/16
  -> Check Point eth2
  -> 东西向 TCP/8080 policy
  -> Gaia route 10.62.0.0/16 via 10.60.1.1
  -> Hub/Remote Azure Global VNet Peering
  -> Remote VM 10.62.0.4
```

返回流量由远端 UDR 再送回 `10.60.1.4`，Check Point state table 根据已有会话放行返回包。

### 可选 DNAT

```text
Approved Internet CIDR
  -> Gateway Public IP:18080
  -> Azure NAT to eth1 10.60.0.4:18080
  -> Check Point Access + DNAT
  -> Gaia route via eth2
  -> EU VM 10.61.0.4:8080
```

## 对应 Terraform 文件

| 内容 | 文件 |
| --- | --- |
| 地址和固定 IP 计算 | `infra/locals.tf` |
| 主 Spoke Hub/Bastion CIDR 补集与路由名计算 | `infra/routing.tf` |
| Check Point VM/NIC/Marketplace module | `infra/checkpoint.tf` + vendored Single Gateway three-NIC patch |
| VNet、subnet、Peering、UDR、NSG | `infra/networking.tf` |
| Workload VM/NIC | `infra/workloads.tf` |
| Windows、Bastion、Windows NIC NSG | `infra/management.tf` |
| Collector、AMA/DCR、LAW、Storage | `infra/logging.tf` |
| 可选 Gaia 静态路由和 R81/R82 policy automation | 用户入口 `scripts/configure-policy.sh`；内部实现 `scripts/checkpoint-policy.sh` |

## 部署后核对

```bash
terraform -chdir=infra output

az network nic show-effective-route-table \
  --subscription "$(terraform -chdir=infra output -raw subscription_id)" \
  --resource-group "$(terraform -chdir=infra output -raw resource_group_name)" \
  --name "$(terraform -chdir=infra output -raw eu_workload_nic_name)" \
  --output table

az network nic show-effective-route-table \
  --subscription "$(terraform -chdir=infra output -raw subscription_id)" \
  --resource-group "$(terraform -chdir=infra output -raw resource_group_name)" \
  --name "$(terraform -chdir=infra output -raw remote_workload_nic_name)" \
  --output table
```

我用 T01/T02 检查两个 NIC 的 effective route table。输出中的 Active
`0.0.0.0/0` 应指向 `VirtualAppliance 10.60.1.4`。
T01/T02 不检查 Bastion 的具体回程或 SSH 凭据；仍需按上文单独确认
`10.60.4.0/26` 的有效路径、TCP/22 和实际登录。effective routes 和连接诊断属于
Azure action，只有 `*/read` 权限时不能以静态 Route Table 回读代替主动连通性结果。
