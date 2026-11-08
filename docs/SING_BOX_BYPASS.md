# 加速 namespace 直接绕过 sing-box

下述配置用于让 bridge 模式的加速 namespace 直接使用宿主物理网络；关闭加速后其中的应用全部直连，包括 Steam Community。社区专用分流暂不实现。运行维护优化和验证步骤见 [OPTIMIZATIONS.md](OPTIMIZATIONS.md)。

## 适用版本与示例

以下示例参考 sing-box [v1.14.2](https://github.com/SagerNet/sing-box/releases/tag/v1.14.2)
及其 go.mod 中的 sing-tun 依赖：
`v0.9.6-0.20260924001923-ddaa4ca25e3b`。本次排除规则参考该精确依赖的源码。

默认 bridge 网络为 `leigod-plugin-bridge`，IPv4 为 `172.21.0.2/16`，
网关为 `172.21.0.1`，宿主网桥为 `leigodbr0`。下文 MAC `02:00:00:00:00:01`
仅为示例，实际配置须使用已保存的 `LEIGOD_DEVICE_MAC`。加速 namespace 关闭 IPv6。

如果 sing-box 日志出现 `inbound redirect connection from 172.21.0.2`，
即使随后使用 `outbound/direct[direct]`，也说明插件连接已被 sing-box 接管和分流。

如果原配置先劫持 DNS、嗅探或拒绝 STUN、UDP/443 和 TCP/853，
在这些操作之后添加源网段 `direct` 规则，无法让加速 namespace 完全绕过处理。
`ip_is_private` 匹配目的地址，也不能排除私网源地址发往公网的流量。

容器原来的 Docker DNS 为 `127.0.0.11`，其外部上游显示
`host(127.0.0.53)`，会让插件自身的域名查询重新依赖宿主解析器。
游戏入口只进入网络 namespace，继续读取宿主 resolv.conf；插件已在该
namespace 提供 `127.0.0.53` DNS stub，上游为 `223.6.6.6`、`114.114.114.114`。
本次让 Docker 外部 DNS 使用同样的直连上游。

插件日志还出现 `getaddrinfo error`、配置获取失败和 `current network is offline`。
这些说明插件有 DNS/网络失败，但日志不足以将所有失败都归因于 sing-box。

## 源码修改

- `docker/compose.bridge.yml` 将专用宿主网桥固定为 `leigodbr0`，避免网络重建后
  Docker network ID 变化导致 `br-<ID>` 排除失效。
- `docker/compose.yml` 为加速容器指定直连 DNS 上游，Docker 内部服务名解析仍由
  `127.0.0.11` 提供，外部查询使用明确配置的上游。
- `libexec/leigod-direct-policy.py` 管理四条 IPv4 策略规则；
  `systemd/leigod-direct-policy.service` 在开机时恢复它们。
- `install.sh` 仅在 bridge 模式安装路由保护，并把 helper 和 systemd 单元纳入
  原有 SHA-256 安装清单。`uninstall.sh` 校验两者的安装清单后停止单元、精确移除规则
  和文件；切换回 macvlan 时也清理此前的 bridge 路由保护。

路由保护按 `LEIGOD_BRIDGE_SUBNET` 生成，默认如下。只在专用网段使用，避免与其他网络重叠。

| 优先级 | 匹配 | 动作 |
|---|---|---|
| 100 | from 172.21.0.0/16 | lookup main |
| 101 | from 172.21.0.0/16 | unreachable |
| 102 | to 172.21.0.0/16 | lookup main |
| 103 | to 172.21.0.0/16 | unreachable |

四条规则标记为 protocol 242。helper 在修改前检查优先级冲突，接受自己已经安装的规则；
删除时校验完整规则，不会按优先级清空其他规则。`main` 路由表由系统维护，Wi-Fi、
有线网络和网关变化时无需把接口名或网关写死在这些规则中。

后续的 `unreachable` 是必要的：sing-box 的自动重定向会在优先级 32768 添加
TUN 备用路由规则。Wi-Fi 默认路由消失时，单独 `lookup main` 查询失败仍会继续查找
后续规则；保护规则使该 namespace 返回不可达，避免改走 TUN。保护不保证断网时仍能联网。

## sing-box 配置

编辑 sing-box 服务实际加载的配置文件（路径以服务配置为准），加入下述排除项。安装器不会自动修改 sing-box 配置。
TUN 新增以下字段：

```json
{
  "exclude_interface": ["leigodbr0"],
  "exclude_mac_address": ["02:00:00:00:00:01"],
  "route_exclude_address": ["172.21.0.0/16"]
}
```

接口排除在 DNS 劫持、TCP 重定向和 TUN 标记之前生效；MAC 排除提供持久设备身份的补充。
如果从自动命名的旧网桥迁移，过渡期间可临时保留实际旧接口的排除项；新网络使用固定 `leigodbr0`。
MAC 只匹配源 MAC，不能独立解决回程。`route_exclude_address` 匹配目的地址，
用于排除发往加速网段的返回流量；它本身不会排除从该网段发往公网的连接。
不要为回程排除整个物理 `wlan0`，那会把其他进入该接口的流量一起排除。

本次保留 `auto_route`、`auto_redirect`、`strict_route` 和 1.14 的 `stack: mixed`。
加速流量不需要新的 sing-box `source_ip_cidr -> direct` 分流规则。
镜像更新或网络参数变化可能替换容器 namespace，更新前须退出 Steam、Ubisoft 和游戏，之后重新启动以进入新 namespace。网络配置一致时安装器保留原 Docker 网络；单独编辑源码不会改变正在运行的容器。

## 官方实现

- [sing-box v1.14.2 TUN 入口](https://github.com/SagerNet/sing-box/blob/v1.14.2/protocol/tun/inbound.go)：传递接口、MAC、地址排除选项。
- [精确 sing-tun 依赖的 nftables 排除规则](https://github.com/SagerNet/sing-tun/blob/ddaa4ca25e3b/redirect_nftables_rules.go)：接口/MAC 排除先于 DNS 劫持和重定向；MAC 匹配 Ethernet 源地址。
- [同依赖的自动路由规则](https://github.com/SagerNet/sing-tun/blob/ddaa4ca25e3b/tun_linux.go)：自动重定向标记与优先级 32768 的备用查表。
- [同依赖的重定向链](https://github.com/SagerNet/sing-tun/blob/ddaa4ca25e3b/redirect_nftables.go)：UDP/ICMP 回程标记处理。
- [Docker bridge 驱动](https://docs.docker.com/engine/network/drivers/bridge/)：`com.docker.network.bridge.name` 固定宿主接口名称。
- [Docker DNS 服务](https://docs.docker.com/engine/network/#dns-services)：自定义网络的内部解析器及显式 DNS 上游。
