# 安全设计与审计记录

## 原实现审计

迁移前的实现由 root systemd service 直接在宿主网络 namespace 中启动闭源程序，主要风险如下：

1. 守护脚本在宿主创建全局 dummy `wlan0`，闭源程序持有修改宿主 TUN、路由、iptables/ipset 所需的完整 root 权限。
2. 官方卸载脚本执行 `iptables -t mangle -F`，会清空不属于本项目的规则；多个卸载路径还会按全局进程名发送 `SIGKILL`。
3. service 没有 capability 收敛、`NoNewPrivileges`、只读文件系统或 syscall/资源隔离。
4. 监控脚本用 `eval` 启动命令；安装、Deb 维护脚本和官方公共脚本各自生成不同 service，存在配置漂移。
5. 资产从明文 HTTP 地址下载，没有签名或哈希验证，并运行自动升级副本。

因此不能在原 systemd 单元上仅增加几个 hardening 选项：加速器的业务本身需要控制路由/TUN，若仍与宿主共用网络 namespace，`NET_ADMIN` 就仍然覆盖宿主网络。

## 当前信任边界

### 容器侧

闭源加速程序以容器 root 运行，但 Docker 先丢弃全部 capability，只返回 `NET_ADMIN` 和 `NET_RAW`。它能完全控制自己的网络 namespace，也能读取/修改 tmpfs、`/tmp` 和专用配置卷；它不能挂载文件系统、进入其他 namespace、读取 Docker socket，或写入宿主目录。

`/dev/net/tun` 是唯一映射设备。DMI product name 是单文件只读 bind mount。镜像根文件系统只读；`/tmp`、`/run` 和 `/var/lib/leigod` 的父运行目录仍是 tmpfs，但 `/var/lib/leigod/config` 由 Docker named volume `leigod-plugin-state` 覆盖，用于保留手机绑定所需的 `accelerator.ini`。该卷不是宿主目录 bind mount，物理位置由 Docker data-root 管理。自动升级 monitor 不启动，因此闭源程序不能通过正常升级路径永久替换镜像内 executable。

### 游戏加入侧

普通用户入口分为三层：

1. `leigod-game-run` 在用户私有 `/run/user/UID` 中以 `0600` 保存 NUL 分隔的原环境。这是为了保留 Lutris 的 Wine/DXVK/VKD3D 变量。
2. sudo 只允许 `leigod-game` 组调用固定的 `leigod-game-enter`。该脚本使用固定 Docker socket/容器名，重新验证容器为 running + healthy、非 privileged、网络名正确、已先 `cap_drop: ALL` 且 capability 只有 `NET_ADMIN`/`NET_RAW`，然后只把 Docker 返回的 PID 交给 0700 的 C helper。
3. C helper 只打开并进入目标 network namespace，不进入容器 mount/PID namespace，也不替换 `resolv.conf`。随后设置 `no_new_privs`、把附加组重建为该桌面用户的真实组（保留 GPU/audio 权限）、清空 ambient capability，并永久降至调用用户 UID/GID。它在降权后才解析用户环境并 `exec` 游戏。

所以 sudo 规则虽然允许附带任意游戏参数，但这些参数不会由 root shell 展开，也不会在降权前执行。

## 网络选择

macvlan 是默认值，因为容器能用独立 LAN 身份与网关通信，无需 host network，局域网发现也无需暴露宿主全部端口。安装器要求明确提供保留 IP，以免自行猜测并撞上 DHCP 租约。

无线网络常限制额外源 MAC。bridge 是显式回退：加速容器仍保留相同 namespace 边界，只发布 Web/API 的 5588/TCP；默认 bind 到 loopback。局域网发现由 `leigod-discover-proxy` sidecar 监听 6066/UDP（`network_mode: host`、非 root、`cap_drop: ALL`、只读根文件系统），只做 NBOX 探测转发并把通告 IP 改写成宿主地址。6066 不经 docker-proxy 发布。程序的 10001/TCP 调试端口不发布。两种配置都没有 `privileged`、host PID/IPC 或 Docker socket。host network 仅用于该开源 sidecar，不用于闭源加速容器。

bridge 直连保护由开源宿主 helper 管理四条仅匹配加速子网的 IPv4 `ip rule`，并由
`leigod-direct-policy.service` 在开机恢复。正常流量查询 `main`；没有路由时返回不可达，
避免被 sing-box 的 TUN 备用路由接管。helper 不修改默认路由或宿主防火墙；规则优先级
100–103 冲突时拒绝覆盖，安装和卸载沿用系统文件 SHA-256 清单。该单元只保留
`CAP_NET_ADMIN`，不会为闭源容器增加宿主网络权限。详见 [SING_BOX_BYPASS.md](SING_BOX_BYPASS.md)。

## 资产完整性

仓库不能为未分发的第三方资产声明可信哈希。安全默认是：本地或下载的资产只要调用者提供了预期 SHA-256 就必须匹配；缺失资产且没有哈希时拒绝 HTTP 自动下载。

`--allow-unverified-download` 仅为迁移保留，必须显式使用。一次 HTTP 下载后显示的哈希不能抵御同路径中间人，不能替代独立发布的签名/哈希。

## 残余风险

- Docker daemon、Linux 内核以及 `NET_ADMIN`/TUN 的内核攻击面仍在可信计算基中；应及时更新内核和 Docker。
- `leigod-plugin-state` 对闭源程序可写，绑定 token 会持久化并可被宿主 root/Docker daemon 读取。当前按部署选择不对卷内既有文件做启动白名单、格式校验或清理；不要把该卷挂载给其他容器，也不要在不可信环境中导出其内容。
- 闭源加速程序可以观察加入该 namespace 的进程流量。不要通过 wrapper 启动密码管理器、浏览器或其他非游戏程序。
- macvlan 容器与物理 LAN 同层，LAN 防火墙仍需把它当独立、不完全可信设备管理。
- namespace helper 依赖容器 PID 在 Docker inspect 与 `setns` 之间保持有效。helper 会重新打开该 PID 的 namespace 并失败关闭，但极端 PID 重用竞态无法仅靠 shell 完全消除。
- 关闭 IPv6 避免绕过，但可能使只支持 IPv6 的游戏/网络不可用。
- Docker 日志转发会脱敏已知 token、nonce、user ID、授权头、密码和加速会话标识，并限制磁盘轮转；这不是对闭源日志格式的完整信息流证明。`info/debug` 仍可能记录游戏域名、IP 或未知敏感字段，日志读取权限和导出文件应按敏感数据管理。
- bridge 发现代理 sidecar 与宿主共用网络命名空间，因此能绑定宿主端口并收发局域网 UDP。它是小型开源程序，以非 root、无 capability、只读根文件系统运行，但不能提供比「宿主上的同等网络进程」更强的网络隔离。

## 安全不变量回归

运行：

```bash
./tests/security-policy.sh
```

该检查会编译 C helper、检查所有 shell 语法、解析 macvlan/bridge 的 Compose 最终配置，并拒绝 privileged、Docker socket、额外容器 capability 或宿主默认路由/防火墙修改。bridge 路由保护只允许管理专用网段的策略规则。host network 只允许出现在 bridge 发现代理 sidecar。

容器健康检查要求 TUN 设备、daemon 进程、Web 控制进程以及 `5588/TCP` 监听同时存在，避免 Web 子进程崩溃时仅凭 daemon PID 继续报告 healthy。
