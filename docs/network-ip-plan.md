# VM、网卡、路由与 IP 规划

本文说明 draw.io 第一、二页使用的字段。Terraform 变量是配置依据。除明确标注
“现场”的内容外，下表使用 `configs/demo.tfvars.example` 的默认值；资源名前缀
可通过 `prefix` 修改。

## 区域和地址空间

| 层级 | 默认区域 | 地址空间 | 用途 |
| --- | --- | --- | --- |
| Hub VNet | West Europe | `10.60.0.0/16` | Check Point 双网卡和日志收集 VM |
| Frontend subnet | West Europe | `10.60.0.0/24` | Check Point `eth0` / External |
| Backend subnet | West Europe | `10.60.1.0/24` | Check Point `eth1` / Internal / NVA next hop |
| Collector subnet | West Europe | `10.60.2.0/24` | rsyslog + Azure Monitor Agent |
| EU Spoke VNet | West Europe | `10.61.0.0/16` | 主工作负载 |
| EU workload subnet | West Europe | `10.61.0.0/24` | 主工作负载 NIC |
| Remote Spoke VNet | North Europe | `10.62.0.0/16` | 远端工作负载 |
| Remote workload subnet | North Europe | `10.62.0.0/24` | 远端工作负载 NIC |

`location` 和 `remote_location` 必须是不同的批准 EU 区域。

## VM 和 NIC 清单

| 角色 | Azure 资源名（默认） | SKU / OS | NIC | 私网 IP | Public IP | IP forwarding |
| --- | --- | --- | --- | --- | --- | --- |
| Check Point standalone | `cpbyol-gateway` | `Standard_D8s_v5`（8C/32GiB）/ Check Point R82 | `cpbyol-gateway-eth0` | `10.60.0.4` | Standard Static，用于管理、出站 NAT 和可选 DNAT | Enabled |
| Check Point standalone | 同一 VM | 同上 | `cpbyol-gateway-eth1` | `10.60.1.4` | 无 | Enabled |
| 主工作负载 | `cpbyol-eu-workload` | `Standard_D4ls_v6`（4 vCPU/8 GiB）/ Ubuntu 24.04 | `cpbyol-eu-workload-nic` | `10.61.0.4` | 无 | Disabled |
| 远端工作负载 | `cpbyol-remote-workload` | `Standard_D4ls_v6`（4 vCPU/8 GiB）/ Ubuntu 24.04 | `cpbyol-remote-workload-nic` | `10.62.0.4` | 无 | Disabled |
| 日志收集 VM | `cpbyol-log-collector` | `Standard_D4ls_v6`（4 vCPU/8 GiB）/ Ubuntu 24.04 | `cpbyol-collector-nic` | `10.60.2.4` | Standard Static，只用于 Azure Agent 初始出站；NSG 不开放公网管理 | Disabled |

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
| `eth0` | `cpbyol-gateway-eth0` | External | `10.60.0.4/24` | Azure Public IP NAT、受限管理入口、互联网出站 |
| `eth1` | `cpbyol-gateway-eth1` | Internal | `10.60.1.4/24` | 所有工作负载 UDR 的下一跳、东西向流量和返回路径 |

`eth1` Anti-Spoofing topology 使用 Management API 枚举值
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

Azure UDR 只把包送入 NVA，不会修改 Check Point Gaia 路由表。
`checkpoint-policy.sh` 创建以下静态路由：

| Destination | Next hop | Egress | 目的 |
| --- | --- | --- | --- |
| `10.61.0.0/16` | `10.60.1.1` | `eth1` | 返回 EU Spoke |
| `10.62.0.0/16` | `10.60.1.1` | `eth1` | 返回 Remote Spoke |
| `10.60.2.0/24` | `10.60.1.1` | `eth1` | Log Exporter 到日志收集 VM |

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
| 100 | `management_cidr` | TCP/22 | SSH |
| 110 | `management_cidr` | TCP/443 | Gaia Portal |
| 120 | `management_cidr` | TCP/18190 | SmartConsole |
| 130 | `management_cidr` | TCP/19009 | SmartConsole |
| 200 | `10.61.0.0/16` | `Any` | 主 Spoke 转发流量 |
| 210 | `10.62.0.0/16` | `Any` | 远端 Spoke 转发流量 |
| 220（条件化） | `inbound_demo_source_cidr` | TCP/18080 | 可选 DNAT 演示 |

管理 CIDR 和可选 DNAT 来源均拒绝 `0.0.0.0/0`。

### Workload NSG

- EU 和 Remote 分别使用同区域 NSG，避免跨区域 NSG 关联失败。
- TCP/8080 只允许 Hub、EU Spoke 和 Remote Spoke。
- 启用 DNAT 时，主工作负载 NSG 额外允许 `inbound_demo_source_cidr`，因为 Check Point 保留原始来源 IP。

### Collector NSG

- UDP/514：只允许 `10.60.1.4/32`。
- TCP/514：只允许 `10.60.1.4/32`，为后续切换 TCP/TLS 预留。
- 不开放公网 SSH；日志收集 VM 的 Public IP 只提供 Azure Agent/extension 初始出站能力。

## 数据面逐包路径

### 互联网出站

```text
EU/Remote VM
  -> 工作负载 UDR 0/0
  -> Check Point eth1 10.60.1.4
  -> Access Control + Geo + Application/URL + HTTPS Inspection
  -> Check Point eth0 10.60.0.4
  -> Azure Public IP NAT
  -> Internet
```

### 跨区域东西向

```text
EU VM 10.61.0.4
  -> EU UDR 10.62.0.0/16
  -> Check Point eth1
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
  -> Azure NAT to eth0 10.60.0.4:18080
  -> Check Point Access + DNAT
  -> Gaia route via eth1
  -> EU VM 10.61.0.4:8080
```

## 对应 Terraform 文件

| 内容 | 文件 |
| --- | --- |
| 地址和固定 IP 计算 | `infra/locals.tf` |
| Check Point VM/NIC/Marketplace module | `infra/checkpoint.tf` |
| VNet、subnet、Peering、UDR、NSG | `infra/networking.tf` |
| Workload VM/NIC | `infra/workloads.tf` |
| Collector、AMA/DCR、LAW、Storage | `infra/logging.tf` |
| Gaia 静态路由和 Check Point policy | `scripts/checkpoint-policy.sh` |

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
