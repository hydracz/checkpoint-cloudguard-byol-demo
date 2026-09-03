# draw.io 架构图说明

可编辑源文件：

- [checkpoint-cloudguard-byol-architecture.drawio](checkpoint-cloudguard-byol-architecture.drawio)

VM、NIC、IP、UDR、Gaia 静态路由、Peering 和 NSG 的字段表：

- [network-ip-plan.md](network-ip-plan.md)

使用 [diagrams.net](https://app.diagrams.net/) 或 draw.io Desktop 打开。
文件采用未压缩 XML，便于检查 Git 差异。

## 页面职责

每一页只回答一个架构问题：

| 页面 | 主要读者 | 内容 | 连线原则 |
| --- | --- | --- | --- |
| `01-现场环境资源与IP` | Azure / 网络实施 | 现场 Region、VNet、subnet、VM、NIC、IP、UDR、Peering、日志资源 | 跨 subnet 归属只用分组和文字；仅保留 subnet 内短线与独立 Peering Bus |
| `02-路由与流量` | 网络 / 防火墙实施 | 出站、跨区域东西向、可选 DNAT、日志转发、私有管理路径 | 每类流量独立横向泳道，线不跨设备 |
| `03-安全策略与TLS` | 安全策略实施 | SmartConsole 手工对象/规则/TLS 规划，以及保留的可选自动化 | 策略与证书各自纵向顺序 |
| `04-部署与审计` | 平台 / 运维 / 合规 | 纯基础设施部署、手工配置交接、独立测试、可选日志导出/WORM | 主流程保持单向；独立测试不接入部署主线 |

## 第一页：现场资源与 IP

第一页用于确认“部署了什么、放在哪里、每块网卡是什么地址”，不承担数据流说明。
Hub 位于画布中央，Primary Spoke 在左、Remote Spoke 在右；底部只画两条独立的
`Spoke ↔ Hub` Peering，绝不画 `Spoke ↔ Spoke` 连接。

### Check Point VM

| 属性 | 值 |
| --- | --- |
| VM | `cpbyol-gateway` |
| Marketplace | Check Point R82 standalone / `mgmt-byol` |
| SKU | 默认 `Standard_D8s_v5`（8 vCPU/32 GiB）；`Standard_F16s` 为容量备用规格 |
| `eth0` NIC | `cpbyol-gateway-management` / `10.60.3.4` / management subnet / Azure primary / 无 Public IP |
| `eth1` NIC | `cpbyol-gateway-frontend` / `10.60.0.4` / frontend subnet / Public IP / IP forwarding |
| `eth2` NIC | `cpbyol-gateway-backend` / `10.60.1.4` / backend subnet / NVA next hop / IP forwarding |

### Workload 和 collector

| VM | NIC / IP | 公网 |
| --- | --- | --- |
| `cpbyol-eu-workload` | `Standard_D4ls_v6`（4C/8GiB）/ `cpbyol-eu-workload-nic` / `10.61.0.4` | 无 |
| `cpbyol-remote-workload` | `Standard_D4ls_v6`（4C/8GiB）/ `cpbyol-remote-workload-nic` / `10.62.0.4` | 无 |
| `cpbyol-log-collector` | `Standard_D4ls_v6`（4C/8GiB）/ `cpbyol-collector-nic` / `10.60.2.4` | 仅用于 Agent bootstrap 出站，不开放公网管理 |
| `cpbyol-windows-client` | `Standard_D4ls_v6`（4C/8GiB）/ `cpbyol-windows-client-nic` / `10.60.3.10` | 无；通过 `cpbyol-bastion` RDP |

页面底部的 Peering Bus 表示：

- Hub ↔ EU Spoke 双向 Peering。
- Hub ↔ Remote Spoke 双向 Azure Global VNet Peering。
- 均启用 `allow_forwarded_traffic`。
- EU 和 Remote 不直接 peering。

## 第二页：路由与流量

每条泳道只从左到右。

### A. 南北向出站

```text
VM -> 0/0 UDR -> Check Point eth2 -> L4/L7/Geo/TLS -> eth1 -> Public IP NAT -> Internet
```

### B. 跨区域东西向

```text
EU VM
  -> EU route table (10.62/16 -> 10.60.1.4)
  -> EU Spoke-to-Hub peering
  -> Hub Check Point eth2
  -> stateful policy
  -> Gaia route (10.62/16 -> 10.60.1.1)
  -> Azure Global VNet Peering
  -> Remote VM
```

返回方向由 Remote route table 把 `10.61.0.0/16` 再送回 `10.60.1.4`。

### C. 可选南北向入站

```text
Approved source CIDR
  -> Public IP:18080
  -> Azure NAT to eth1
  -> Check Point Access + DNAT
  -> Gaia route / eth2
  -> EU workload NSG
  -> 10.61.0.4:8080
```

### D. 日志内部路径

```text
Check Point Log Server
  -> Gaia route 10.60.2.0/24 via 10.60.1.1
  -> cp_log_export UDP/514
  -> collector 10.60.2.4
  -> AMA/DCR/Log Analytics/Storage
```

### E. 私有管理路径

```text
Operator -> Azure Bastion -> Windows 10.60.3.10
  -> SmartConsole / Gaia Portal
  -> Check Point eth0 10.60.3.4
```

Gateway Public IP 只绑定 `eth1`，frontend/backend NSG 不开放管理端口。

## 第三页：手工安全策略与保留自动化

默认在 Windows 管理工作站上用 SmartConsole 手工完成本页内容。R81/R82
`configure-policy.sh` 仍保留，但只能作为部署后的私网显式操作，不由 `deploy.sh` 调用。

### 策略对象

- `CloudGuard-Protected-Networks`：EU 和 Remote `/16`。
- Geo Updatable Objects：从 Check Point repository 精确查询并导入。
- Application/Site：自定义 Domain/URL 和内置 `P2P File Sharing` category。
- Host/Service：EU Web Host、内置 `HTTP_proxy` TCP/8080 和可选 TCP/18080。

### Access Rule 顺序

1. Allow Gateway Services。
2. Allow Restricted Management SSH。
3. Block Geo Inbound。
4. Block Geo Outbound。
5. Block Domains / URLs / Applications。
6. Optional Restricted North-South Inbound。
7. Allow Inspected East-West Web。
8. Allow Web and DNS Egress。
9. Cleanup Drop。

规则名、动作和日志级别都在页面中央纵向排列，没有跨列连接。

### TLS trust 关系

页面右侧单独显示：

1. Check Point Management 生成 `CloudGuardDemoOutboundCA`。
2. CA `issued-by` 来自 `company_domain`，默认值是 `example.org`。
3. HTTPS layer 使用该 CA 对受保护出站进行 Inspect。
4. 只返回 public CA 到 `.local/checkpoint-demo-ca.pem`。
5. EU 和 Remote VM 执行 `update-ca-certificates`。
6. T07 检查叶子证书 issuer 是否与 `company_domain` 一致。

## 第四页：部署与审计

### 默认与可选步骤

1. 预检工具、Marketplace 镜像、VM SKU 和 Terraform 配置。
2. 接受 Marketplace Terms。
3. Terraform 部署 VNet、三网卡 Gateway、Windows、Bastion、AMA/DCR、Log Analytics、Storage 和 `Unlocked` WORM。
4. 输出私网管理地址和凭据；默认流程到此结束，不执行 Check Point policy 配置。
5. 管理员通过 Bastion/Windows 手工配置 Gaia 和 SmartConsole。
6. `scripts/test.sh` 独立执行本地 Terraform/mock tests；手工策略完成后再按需运行 `validate-existing.sh`。
7. 可选运行 `enable-audit-export.sh` 和不可逆 WORM lock。

### 日志与 WORM

```text
Check Point Extended Log
  -> cp_log_export
  -> rsyslog collector
  -> AMA + DCR
  -> EU Log Analytics
  -> Continuous Export
  -> EU GRS Storage / am-syslog
```

默认 Immutability Policy 为 `Unlocked`。执行 `lock-worm.sh --yes` 后，
Azure 应返回 `Locked`；该状态不能恢复为 `Unlocked`。

## 图例

| 样式 | 含义 |
| --- | --- |
| 蓝色 | Azure route、受控网络引流 |
| 绿色 | 内部返回路径、Peering、允许规则 |
| 红色 | Check Point enforcement、Drop、不可逆动作 |
| 橙色 | Public IP、外部流量入口、条件化 DNAT、警告 |
| 紫色 | TLS、日志、Log Analytics、Storage/WORM |

## 维护规则

- Terraform CIDR、IP、区域、SKU、网卡或策略顺序变化时，同步更新 draw.io 和 [network-ip-plan.md](network-ip-plan.md)。
- 第一页不增加业务流量线；新数据流只能放在第二页的新泳道中。
- 长距离关系优先用独立 Bus 或表格表达，不用穿越多个设备的连接线。
- 图中不加入 subscription ID、tenant ID、client secret、SIC key、许可证或真实管理员公网 IP。
