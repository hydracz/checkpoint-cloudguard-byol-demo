# 技术要求与配置映射

| 要求 | 配置位置 | 配置方式 | 复查方法 | 会影响什么决定 |
| --- | --- | --- | --- | --- |
| 五元组访问控制 | `checkpoint-policy.sh` 中的 Network、Host、Service 和 Access Rule | 脚本 | T03、T08 | Policy 必须安装到已授权 Gateway |
| 域名和 URL | 自定义 `application-site`；`blocked_urls` | 脚本 | T05、T06 | HTTPS path 需要 HTTPS Inspection 才可见 |
| 应用特征 | Application Control；`blocked_applications` | 脚本 | T08 | 默认使用内置 `P2P File Sharing` category；其他对象需要 AppWiki 已下载 |
| TLS 解密 | Outbound Inspection Certificate、HTTPS layer/rule、演示 CA trust | 脚本 | T07 | 生产设计需要隐私例外、企业 CA 和法律评审 |
| 国家/地区 Geo-IP | Updatable Objects Repository；双向 Geo `Drop` | 脚本 | T08 | Geo 数据表示 IP 归属，不表示人员或数据的物理位置 |
| 南北向出站 | 工作负载 `0.0.0.0/0` UDR → Gateway；Hide NAT | Terraform + 脚本 | T01、T02、T04 | 单实例不提供生产 High Availability |
| 南北向入站 | 可选 TCP/18080 NSG、Access Rule 和 DNAT | 条件化脚本 | T13 | 默认关闭；只接受指定来源 CIDR |
| VPC/VNet 东西向 | 两个 Spoke 的对端前缀 UDR → Gateway；Gaia 从 `eth1` 返回 | Terraform + 脚本 | T03 | Azure 中对应的网络资源是 VNet |
| 跨地域私网 | 两个 EU region 通过 Azure Global VNet Peering 连接 | 对比路径 | T02、T03 | 不表示 ExpressRoute 或运营商专线已经验证 |
| 流量日志审计 | `Extended Log`、Log Exporter、日志收集 VM、Azure Monitor Agent、Log Analytics | Terraform + 脚本 | T09、T10 | Azure Monitor 摄取存在延迟 |
| 欧盟内存储 | Log Analytics 和 GRS Storage 位于配置的 EU region | Terraform | T12 | 客户仍需结合合同和 Azure EU Data Boundary 复查 |
| 防篡改长期留存 | `am-syslog` 365 天 protected append WORM | Terraform + 显式锁定 | T11 | 只有执行不可逆 lock 后才是 `Locked` |
| Marketplace BYOL | module `1.3.2`、R82/R82.10 offer、`standalone` `mgmt-byol` | Terraform | `preflight.sh` 和 Terraform plan | BYOL entitlement 由客户提供并激活 |

## 结论限制

- `Unlocked` Immutability Policy 不等于 Locked WORM。
- `terraform apply` 完成不等于 Check Point policy 已安装；还要复查 `fw stat`
  和 Management API。
- 路由存在不等于流量已被检查；还要观察 T03-T10 的流量、策略和日志字段。
- 本演示没有检查生产吞吐、High Availability、升级、RTO/RPO、
  ExpressRoute SLA 或所有国家对象的准确度。
