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

资源名：`cpbyol-eu-workload-rt`

| 路由名 | Prefix | Next hop type | Next hop IP | 目的 |
| --- | --- | --- | --- | --- |
| `default-via-checkpoint` | `0.0.0.0/0` | `VirtualAppliance` | `10.60.1.4` | 所有互联网出站经 Check Point |
| `remote-spoke-via-checkpoint` | `10.62.0.0/16` | `VirtualAppliance` | `10.60.1.4` | 主工作负载 → 远端工作负载 |
| `hub-via-checkpoint` | `10.60.0.0/16` | `VirtualAppliance` | `10.60.1.4` | 主工作负载访问 Hub 时仍经过 Check Point |

### 远端工作负载 Route Table

资源名：`cpbyol-remote-workload-rt`

| 路由名 | Prefix | Next hop type | Next hop IP | 目的 |
| --- | --- | --- | --- | --- |
| `default-via-checkpoint` | `0.0.0.0/0` | `VirtualAppliance` | `10.60.1.4` | 所有互联网出站经 Check Point |
| `eu-spoke-via-checkpoint` | `10.61.0.0/16` | `VirtualAppliance` | `10.60.1.4` | 远端工作负载 → 主工作负载 |
| `hub-via-checkpoint` | `10.60.0.0/16` | `VirtualAppliance` | `10.60.1.4` | 远端工作负载访问 Hub 时仍经过 Check Point |

BGP route propagation 在两个工作负载 Route Table 上关闭，避免未来专线路由在
未评审时覆盖演示 UDR。

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
