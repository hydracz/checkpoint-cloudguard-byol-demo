# Azure 资源与流量路径

架构图、图注和地址表：

- [checkpoint-cloudguard-byol-architecture.drawio](checkpoint-cloudguard-byol-architecture.drawio)
- [drawio-architecture.md](drawio-architecture.md)
- [network-ip-plan.md](network-ip-plan.md)

## Azure 资源关系

| 区域 | 网络 | 资源 |
| --- | --- | --- |
| Primary EU（默认 West Europe） | Hub `10.60.0.0/16` | Check Point management/frontend/backend 三网卡、日志收集 VM、私有 Windows 管理工作站、Azure Bastion、Log Analytics、GRS Storage |
| Primary EU | EU Spoke `10.61.0.0/16` | 无公网 IP 的工作负载 VM `10.61.0.4` |
| Secondary EU（默认 North Europe） | Remote Spoke `10.62.0.0/16` | 无公网 IP 的工作负载 VM `10.62.0.4` |

Hub 与两个 Spoke 分别创建双向 Azure Global VNet Peering，并启用
`allow_forwarded_traffic`。两个 Spoke 不直接 Peering，避免 Azure 系统路由绕过防火墙。

## 强制流量路径

每个工作负载子网都有三条用户定义路由（UDR）：

1. `0.0.0.0/0` → `10.60.1.4`，控制互联网出站。
2. 对端 spoke `/16` → `10.60.1.4`，控制跨区域东西向。
3. Hub `/16` → `10.60.1.4`，控制工作负载访问 Hub 服务。

Check Point `eth0` 为 Management（`10.60.3.4`）、`eth1` 为 External/Frontend
（`10.60.0.4` + Public IP）、`eth2` 为 Internal/Backend（`10.60.1.4`）。
管理员手工配置或可选内网脚本把两个 Spoke 和日志收集子网的 Gaia 静态路由指向
后端子网的 Azure 虚拟网关，并把 `eth2` Anti-Spoofing topology 设为
`network defined by routing`。
Azure UDR 把工作负载流量送入网络虚拟设备（NVA）；Gaia 静态路由让检查后的
流量从 `eth2` 返回，互联网流量从 `eth1` 发出。

Windows 管理工作站与 Check Point `eth0` 位于 Hub 的独立 `10.60.3.0/24`
management subnet，地址分别为 `10.60.3.10` 和 `10.60.3.4`，均没有 Public IP。
Basic Azure Bastion 位于专用 `AzureBastionSubnet 10.60.4.0/26`，是工作站唯一的
RDP 入口。工作站以后用于安装与 Gaia 版本匹配的 SmartConsole，并通过私网连接
Check Point management IP。Gateway Public IP 只绑定 `eth1`，数据平面 NSG 不允许
任何 Internet/Public CIDR 访问 SSH、Gaia Portal 或 SmartConsole 端口。

## Access Control 与 HTTPS Inspection

默认由 Windows 上的 SmartConsole / Gaia Portal 手工执行以下配置：

- 创建 Network object、Host、Service 和受保护网络组。
- 启用 Firewall、Application Control 和 URL Filtering Software Blade。
- 导入客户选择的 Geo Updatable Objects。
- 创建带 `Extended Log` 的 Geo、Application/Site、东西向和互联网规则，并在末尾放置默认 `Drop`。
- 可选创建来源受限的入站 Access Rule 和手动 DNAT。
- 生成/导入 Outbound CA，创建出站 HTTPS layer 和 `Inspect` 规则，然后安装 policy。

CA 私钥保留在 Check Point Management。仓库保留 R81/R82 自动化实现，但
`deploy.sh` 不调用；以后只能从 management subnet 或可信私网显式执行。

## 审计链路

1. `cp_log_export` 从 `standalone` Management/Log Server 以 generic syslog 发送到 `10.60.2.4:514/UDP`。
2. Ubuntu `rsyslog` 接收日志；Azure Monitor Agent 按 Data Collection Rule（DCR）写入 EU Log Analytics `Syslog` 表。
3. 显式运行 `enable-audit-export.sh` 时，脚本写入 bootstrap syslog，以数值计数查询最多等待 30 分钟；每 5 次重发记录并显示进度，`Syslog` 表可查询后再创建 Continuous Data Export。
4. `am-syslog` 允许 protected append writes。默认保留 365 天，状态为 `Unlocked`；显式锁定后成为 Write Once, Read Many（WORM）存储。

Storage 使用 Geo-Redundant Storage（GRS）。上线前需要根据 Microsoft 当前
EU Data Boundary、所选区域配对和客户合同复查数据位置。

审计 Storage、private container 和 WORM policy 通过 ARM management-plane
template 部署，因此即使客户 Azure Policy 强制 `publicNetworkAccess=Disabled`、
禁用共享密钥，首次 Terraform apply 也不需要访问 Storage data-plane。生产可在
此基础上增加 Private Endpoint 和 Private DNS，供受控审计读取。

## 生产设计需要调整的组件

- 当前 standalone → 独立 Management Server + 多 Gateway，再按生产要求选择 Gateway HA/VMSS；management subnet 和 `eth0` 角色保持不变。
- Azure Global VNet Peering → ExpressRoute、Virtual WAN 或 VPN 私网前缀；UDR 下一跳仍指向受支持的 Check Point HA/ILB 地址。
- 演示 Outbound CA → 企业 PKI 管理的 Inspection CA、完整 bypass policy 和终端 MDM/GPO 分发。
- UDP syslog → 依据客户威胁模型改为 Check Point Log Exporter 支持的 TCP/TLS 目标链路。
