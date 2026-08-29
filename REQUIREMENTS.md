# 防火墙需求与检查条件

本文件保留创建 Demo 时使用的防火墙需求，使独立仓库不依赖父目录中的材料。

## 客户需求

1. **4/7 层流量管控**：支持基于五元组、域名、URL、应用特征的访问控制和 TLS 解密。
2. **跨境数据管控**：支持基于国家/地区 Geo-IP 的精细跨境流量阻断。
3. **全流量覆盖**：覆盖南北向互联网出入流量，以及 VPC/VNet 和跨地域私网的东西向流量。Azure 中对应的网络资源是 Virtual Network（VNet）。
4. **日志审计**：支持流量日志审计；日志存储在欧盟内，并支持防篡改、长期留存。
5. **产品及许可**：使用 Azure Marketplace 的 Check Point CloudGuard/Cloud Firewall，采用 Bring Your Own License（BYOL）。
6. **交付形式**：独立目录，通过 Terraform 和脚本按顺序创建基础设施、策略和日志导出。

## 可复查条件

| 编号 | 检查条件 |
| --- | --- |
| R1 | 两个工作负载子网的 `0.0.0.0/0` 和对端 Spoke 前缀都显示 Active，下一跳为 Check Point 后端 IP `10.60.1.4`，类型为 `VirtualAppliance`。 |
| R2 | Check Point Access Control 包含五元组、域名/URL、Application Control、双向 Geo `Drop` 和默认拒绝规则；规则开启日志。 |
| R3 | 启用 TLS 时，Management API 创建 Outbound CA 和 `Inspect` 规则；两台工作负载 VM 只安装公钥 CA。 |
| R4 | 两个 EU Azure 区域的工作负载可以通过 Check Point 访问对端 TCP/8080；公网出站也经过 Check Point。 |
| R5 | `cp_log_export status` 显示 `azure-monitor` 为 `Running`；EU Log Analytics `Syslog` 表出现 Check Point 记录。 |
| R6 | `Syslog` 表持续导出到同区域 Storage 的 `am-syslog` 容器；Immutability Policy 不少于 30 天。 |
| R7 | 执行 `lock-worm.sh --yes` 后，Immutability Policy 显示 `Locked`。`Unlocked` 状态不表示已满足不可篡改要求。 |
| R8 | 默认 Marketplace 路径的 `publisher`、`offer`、`plan` 分别为 `checkpoint`、所选 R82/R82.10 offer、`mgmt-byol`；custom image 必须保留可审计来源，并按来源正确保留 Plan，或明确记录为已获授权的 R81 无 Plan 镜像。 |

## 必须由客户提供或确认的内容

- Check Point BYOL entitlement，以及覆盖 Firewall、Application Control、URL Filtering、HTTPS Inspection 等所需 Software Blade 的许可证。
- 客户批准的阻断国家/地区、应用、域名和 URL 清单。
- 管理员公网来源 CIDR；演示拒绝 `0.0.0.0/0` 管理入口。
- 生产 TLS Inspection 的企业 CA 生命周期、例外清单、隐私/法律评审和终端信任分发方案。
- 生产日志保留年限及是否执行不可逆 WORM lock。
- 生产跨地域专线（ExpressRoute、Virtual WAN 或 VPN）参数。本演示使用 Azure Global VNet Peering 验证跨区域私网路径，不创建 ExpressRoute 电路。
