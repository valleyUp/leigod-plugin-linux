# Leigod Plugin — Linux 安全隔离版

本项目让雷神 Steam Deck 插件在 x86_64 Linux 上运行，并把闭源加速程序限制在独立 Docker 网络命名空间中。默认使用 macvlan；宿主机和普通应用不进入加速网络，只有通过 `leigod-game-run` 启动的 Lutris/Wine 游戏进程会加入该命名空间。

> 本仓库不分发、修改或逆向雷神二进制。使用雷神服务时请遵守其服务条款。

## 隔离模型

```text
宿主默认网络                   Docker: leigod-plugin 网络命名空间
┌─────────────────────┐       ┌──────────────────────────────────┐
│ 浏览器、聊天、更新器 │       │ acc-gw + wlan0(Docker) + TUN     │
│ Lutris 主界面         │       │ iptables/ipset（仅此命名空间）    │
└──────────┬──────────┘       └──────────────┬───────────────────┘
           │                                 │
           └─ 游戏命令前缀 → 降权/setns ─────┘
                         Wine/游戏子进程
```

安全边界：

- Compose 明确设置 `privileged: false`。加速容器从不使用 `network_mode: host`；bridge 模式下仅开源发现代理 sidecar 使用 host network，以便接收局域网 UDP 广播。
- 容器先丢弃全部 capability，再只加入 `NET_ADMIN`、`NET_RAW`；只映射 `/dev/net/tun`。
- 根文件系统只读，并启用 `no-new-privileges`、PID/内存/CPU 上限和默认 seccomp。
- Steam Deck DMI 文件只读挂载；容器没有 Docker socket，也没有宿主目录写挂载。
- 手机绑定配置保存在 Docker named volume `leigod-plugin-state`，只挂载到容器的 `/var/lib/leigod/config`；不会把仓库或用户目录以可写方式暴露给闭源程序。
- `wlan0`、路由、iptables、ipset 和 TUN 都只存在于容器网络命名空间。
- 游戏入口只进入目标 network namespace，不进入容器 mount/PID namespace，也不替换宿主 `resolv.conf`；随后把附加组重建为桌面用户的真实组（保留 GPU/audio 权限）、清空 capability、降回桌面用户，最后才恢复 Lutris 环境并执行游戏。
- IPv6 在加速命名空间中关闭，避免不受支持的 IPv6 流量绕过 IPv4 TUN。
- 自动更新监控不在镜像中运行；升级通过重新校验、构建镜像完成。

实际部署请先阅读 [docs/USAGE.md](docs/USAGE.md)，其中分别给出 macvlan/bridge 配置、手机发现、Lutris 使用、脚本调用链和故障定位。更完整的审计、信任边界和残余风险见 [docs/SECURITY.md](docs/SECURITY.md)；宿主安装内容与仓库内构建边界见 [docs/IMPLEMENTATION_REVIEW.md](docs/IMPLEMENTATION_REVIEW.md)。

## 系统要求

- x86_64 Linux，内核提供 TUN、macvlan（使用 bridge 回退时可无 macvlan）
- Docker Engine 和 Docker Compose v2
- `cc`、`curl`、`iproute2`、`sudo`、`sha256sum`
- 安装时具有 root 权限；游戏本身以普通桌面用户运行

不要把桌面用户加入 `docker` 组：该组通常等价于 root。游戏入口使用受限 sudo 规则，只允许调用会在执行游戏前降权的固定 helper。

## 准备官方资产

安装需要两个不纳入 Git 的官方文件：

```text
opt/leigod/acc-gw.router.amd64
opt/leigod/config/ipdatacloud_country.xdb
```

推荐从可信来源取得文件，并通过独立渠道得到 SHA-256。即使文件已在本地，传给安装器的哈希仍会验证：

```bash
sha256sum opt/leigod/acc-gw.router.amd64 \
  opt/leigod/config/ipdatacloud_country.xdb
```

如果本地文件不存在，安装器可以从旧版官方 HTTP 地址下载，但默认要求对应的预期哈希。`--allow-unverified-download` 是显式、不推荐的兼容开关；安装器会显示实际哈希，不能把它视为独立完整性证明。

## 构建容器

```bash
docker build --pull --build-arg LEIGOD_VERSION=1.2.2.15 \
  -f docker/Dockerfile -t leigod-plugin:1.2.2.15 .

# 仅 bridge 模式需要发现代理
docker build --pull \
  -f docker/Dockerfile.discover-proxy \
  -t leigod-discover-proxy:1.2.2.15 .
```

## 启动容器

运行配置在 `.leigod/docker.env`（完整安装由 `install.sh` 生成；也可从 `config/docker.env.example` 复制后按本机修改）。

macvlan：

```bash
docker compose --env-file .leigod/docker.env --project-directory . \
  -f docker/compose.yml -f docker/compose.macvlan.yml up -d
```

bridge（同时启动加速容器和 host-network 发现代理）：

```bash
docker compose --env-file .leigod/docker.env --project-directory . \
  -f docker/compose.yml -f docker/compose.bridge.yml up -d
```

## 安装：macvlan（首选）

先从路由器 DHCP 池之外预留一个未占用地址。安装器会尝试从默认路由推断 parent、subnet 和 gateway，但不会猜测安全的静态地址：

```bash
sudo ./install.sh \
  --ip 192.168.1.240 \
  --binary-sha256 <64位SHA-256> \
  --xdb-sha256 <64位SHA-256>
```

自动检测不适用时完整指定：

```bash
sudo ./install.sh \
  --network macvlan \
  --parent enp3s0 \
  --subnet 192.168.1.0/24 \
  --gateway 192.168.1.1 \
  --ip 192.168.1.240 \
  --user "$USER" \
  --binary-sha256 <64位SHA-256> \
  --xdb-sha256 <64位SHA-256>
```

macvlan 让容器在局域网中拥有独立 MAC/IP，不需要 host network 或端口泛化映射。macvlan 的正常限制是宿主不能直接访问 macvlan 子接口；游戏通过加入容器 namespace 访问，不依赖宿主到容器连通。

很多 Wi-Fi 驱动/AP 不允许同一无线客户端呈现多个 MAC。如果 macvlan 在无线 parent 上失败，使用下列显式回退。

## 安装：bridge 回退

```bash
sudo ./install.sh \
  --network bridge \
  --binary-sha256 <64位SHA-256> \
  --xdb-sha256 <64位SHA-256>
```

加速容器仍使用独立网络命名空间，并不使用 host network。默认只把 Web/API 的 `5588/TCP` 映射到 `127.0.0.1`。手机 App 需要从同一 Wi-Fi 发现并识别为 Steam Deck 时，须显式加 `--bind-address 0.0.0.0`，并用宿主防火墙允许可信局域网访问 `5588/TCP` 和 `6066/UDP`。

闭源程序在容器里通告的是 Docker 网桥地址，手机连不上。因此 bridge 模式会启动 `leigod-discover-proxy` sidecar（host network、非 root、无额外 capability）：接收局域网 `<NBOX> HELLO` 广播/单播，转给加速容器，并把应答里的 `ip=` 改写成宿主局域网地址。6066/UDP 不经 docker-proxy 发布。`10001/TCP` 是程序标明的调试端口，不对外发布。

安装完成后注销并重新登录一次，使 `leigod-game` 组成员身份生效。

## 只加速 Lutris/Wine 游戏

推荐保持 Lutris 主界面在宿主默认网络，仅对单个游戏设置命令前缀。在 Lutris 对应游戏的 Runner/System options 中，把 **Command prefix** 设置为：

```text
/usr/bin/leigod-game-run --
```

Lutris 会把 Wine runner 及其游戏子进程放入加速网络，而 Lutris 主界面、浏览器等仍使用宿主网络。也可以直接运行：

```bash
leigod-game-run -- wine /path/to/game.exe
```

如果需要调试整个 Lutris 进程树，可临时运行 `leigod-game-run -- lutris`，但这也会让 Lutris UI 自身使用加速网络，不是默认推荐方式。

## 验证

确认加速容器没有 privileged/host network，并查看能力和网络驱动：

```bash
docker inspect leigod-plugin --format \
  'privileged={{.HostConfig.Privileged}} network={{.HostConfig.NetworkMode}} caps={{json .HostConfig.CapAdd}}'
docker network inspect leigod-plugin-macvlan --format '{{.Driver}}'
docker logs --tail 100 leigod-plugin
```

正常结果应包含 `privileged=false`、`network=leigod-plugin-macvlan`（或 bridge 回退网络），且能力只有 `NET_ADMIN`、`NET_RAW`。容器健康检查同时要求 daemon、Web 控制进程和 `5588/TCP` 监听存在；仅有 daemon PID 不再判定为 healthy。

闭源程序把主要运行日志写入容器 `/tmp/acc/log`，入口会轮转感知地转发到 stdout，并用 `[leigod:daemon]`、`[leigod:web]`、`[leigod:game]` 和 `[leigod:console]` 标记来源。默认只转发 `WARN/ERROR`，连续相同消息会折叠计数，已知 token、nonce、user ID、授权头、密码和加速会话标识会脱敏。Docker `json-file` 日志限制为 3 个、每个 10 MiB。

安装时可用 `--log-level off|error|warn|info|debug` 调整详细程度。例如临时排障可重新执行原安装命令并增加 `--log-level info`，结束后恢复 `warn`。`info/debug` 仍可能包含游戏访问的域名、IP 和闭源程序尚未识别的敏感字段，不建议长期启用或直接公开日志。

bridge 模式确认手机发现通告的是宿主 LAN 地址而不是 `172.x`：

```bash
python3 - <<'PY'
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(2)
s.sendto(b"<NBOX> HELLO", ("127.0.0.1", 6066))
print(s.recv(4096))
PY
```

应答应包含 `model=SteamDeck` 以及 `ip=<本机局域网地址>`。

若日志出现 `create dir /home/leigod failed`、`config dir or path is empty`，说明运行的仍是缺少 Steam Deck 路径兼容层的旧镜像。重新执行原安装命令会重建镜像并重建容器；修复后的 `/home/leigod` 只是镜像内指向 `/opt/leigod` 的只读符号链接，不会映射宿主目录。

比较普通 shell 与游戏 namespace 的公网出口时，可使用你信任的查询服务：

```bash
curl https://example.invalid/ip
leigod-game-run -- curl https://example.invalid/ip
```

上面的域名只是占位符，请替换为自己的出口检查服务。第二条命令只有在容器 healthy 且当前用户已获得组权限时才会执行。

## 管理与卸载

Docker 构建直接使用当前仓库；生成的运行配置保存在 `.leigod/docker.env`，系统安装文件及其 SHA-256 清单保存在 `.leigod/install-manifest`。因此安装后不要移动或删除此仓库，否则容器重建、切换网络模式和卸载会失去 Compose/DMI 源文件及安全卸载依据。

```bash
docker logs -f leigod-plugin
docker restart leigod-plugin
sudo ./uninstall.sh                       # 保留镜像和手机绑定状态卷
sudo ./uninstall.sh --purge               # 删除镜像，仍保留绑定状态卷
sudo ./uninstall.sh --purge-state         # 删除绑定状态卷，保留镜像
sudo ./uninstall.sh --purge --purge-state # 同时删除镜像和绑定状态卷
```

手机绑定状态位于 Docker named volume `leigod-plugin-state`，镜像重建、容器重建和普通卸载后继续保留；只有显式 `--purge-state` 且卷的 Compose 项目/逻辑卷标签均匹配时才会删除。`/tmp`、`/run`、日志、锁、DHCP 租约和网络状态仍位于 tmpfs，容器重建即消失。当前入口脚本只补齐卷中缺失的模板文件，不对已有绑定配置做白名单、格式校验或清理。

普通卸载后该卷会变成未使用卷；若仍需保留绑定，不要对它执行 `docker volume rm`，也不要运行会删除未使用卷的 `docker volume prune`。

卸载不会刷新宿主 iptables、不会按全局进程名杀进程，也不会修改宿主默认路由。卸载器只删除清单中存在且内容哈希仍匹配的固定系统文件；修改过、无法验证或被替换为符号链接的文件会保留并报警。`leigod-game` 组也会保留，以免卸载脚本擅自改写已有用户的组成员关系。

## 仓库结构

```text
docker/          镜像入口与 Compose 隔离策略
src/             最小化 setns/降权 helper（C）
bin/             普通用户游戏启动器
libexec/         root 侧受限容器检查入口
sudoers/         leigod-game 组的固定命令授权
config/          Docker 环境配置示例
tests/           静态安全策略回归
opt/leigod/      伪装文件、配置模板和本地官方资产位置
```

通用源码包可用 `packages/build-tar.sh` 构建；包内包含 bridge 发现代理镜像构建文件，但不包含第三方二进制。安装仍需在目标机器上提供/校验官方资产并配置网络。

## 免责声明

本项目只通过容器、Linux namespace、只读文件挂载和网络设备配置模拟运行环境，不修改雷神核心程序。闭源程序即使在容器中仍拥有该容器网络 namespace 的 `NET_ADMIN` 权限，也能看到经该 namespace 传输的游戏流量；容器隔离降低宿主影响面，但不能把闭源程序变成可信代码。

本项目仅供学习研究。请遵守当地法律法规和服务条款。
