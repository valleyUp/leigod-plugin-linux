# 当前实现、构建与使用审查说明

本文描述仓库当前代码的实际行为，供安全和部署审查使用。

## 1. 结论摘要

当前设计把雷神私有二进制放在 Docker 容器中运行；Lutris/Wine 游戏仍是宿主普通用户进程，只加入容器的 network namespace。游戏不会进入容器的 mount 或 PID namespace，雷神二进制也没有挂载宿主 HOME、游戏目录或 Wine prefix。

Docker 镜像直接以当前仓库为 build context，不再复制到 `/opt` 或其他系统构建目录。除需要系统安装的可执行文件和 sudoers 规则外，项目生成的持久文件都留在当前仓库：

- 运行配置：`.leigod/docker.env`
- 系统安装清单：`.leigod/install-manifest`（固定系统路径及安装后 SHA-256，`0600`）
- 下载的雷神二进制：`opt/leigod/acc-gw.router.amd64`
- 下载的 IP 数据库：`opt/leigod/config/ipdatacloud_country.xdb`
- 源码包：`packages/`
- 临时编译目录：仓库内 `.leigod-build.*`，安装结束时清理

Docker 镜像、build cache、容器、网络和手机绑定状态卷由 Docker daemon 管理，物理存储位置由 Docker 的 data-root 决定，不能由本项目限制在 Git 仓库内。这是容器运行时数据，不是安装脚本复制到 `/opt` 的项目文件。

每次启动游戏时，`leigod-game-run` 还会在 `/run/user/<UID>` 创建一个 `0600` 的短生命周期环境快照，用于安全地把 Lutris/Wine 环境跨越 sudo 边界传给降权后的游戏；wrapper 退出时立即删除。它不是构建或持久部署产物，放在用户 runtime tmpfs 而不是仓库中可避免泄漏、并发冲突和残留。

安装完成后，安装器对下表中的每个系统文件计算 SHA-256，并以固定绝对路径写入 `.leigod/install-manifest`。清单只作为固定白名单文件的所有权证据，卸载器不会执行清单中的路径，也不会用它删除任意位置。

系统路径上持久落下的只有 launcher、两个 libexec 程序和一条 sudoers。bridge 发现代理作为 Docker sidecar 运行，不再写入 `/usr` 或 `/etc/systemd`。绑定配置保存在 Docker named volume，其余运行状态在容器或进程退出后消失。安装器对宿主网络栈的影响见 [2.5](#25-安装器对系统环境的影响)。

因为 Compose 和 DMI bind mount 都直接引用当前仓库，安装后不能移动或删除仓库；更新、网络模式切换、容器重建和卸载也应在同一目录进行。

## 2. 宿主安装内容

`install.sh` 必须以 root 运行。它**不会**改宿主默认路由、**不会**改宿主 iptables/nftables、**不会**改 `/etc/resolv.conf`、**不会**把桌面用户加入 `docker` 组。系统包管理器、内核模块、发行版网络配置都不由本项目安装。

### 2.1 系统级文件

安装器向系统路径写入的文件如下。`cc` 在仓库内临时目录编译 namespace helper；shell 脚本按原样安装。发现代理在 Docker 构建中编译，不以宿主文件安装。

| 仓库来源 | 安装位置 | 权限 | 何时安装 | 用途 |
|---|---|---|---|---|
| `bin/leigod-game-run` | `/usr/bin/leigod-game-run` | `0755` | 始终 | Lutris Command prefix；把环境写入 `/run/user/<UID>` 后调用 sudo helper |
| `libexec/leigod-game-enter` | `/usr/local/libexec/leigod-game-enter` | `0755` | 始终 | root 侧检查容器 running/healthy、非 privileged、网络名、capability，再交出 PID |
| `src/leigod-netns-exec.c`（现场编译） | `/usr/local/libexec/leigod-netns-exec` | `0700` | 始终 | `setns` 进容器 netns；不改 DNS/resolv.conf；降权后 exec 游戏 |
| `sudoers/leigod-game`（经 `visudo -c`） | `/etc/sudoers.d/leigod-game` | `0440` | 始终 | 仅允许 `leigod-game` 组对固定路径 `NOPASSWD` 调用 `leigod-game-enter` |

bridge 模式从 `src/leigod-discover-proxy.c` 构建 `leigod-discover-proxy` 镜像，不在宿主安装发现代理二进制或 systemd 单元。

### 2.2 账户与授权

- 若不存在则 `groupadd --system leigod-game`。
- `usermod -a -G leigod-game <桌面用户>`：只追加组，不改登录 shell、不改密码、不加入 `docker` 组。
- 新组成员关系要等该用户**重新登录**后，当前桌面会话的 `id` 才会带上 `leigod-game`；未刷新时 Lutris 的 `sudo -n` 会失败。
- sudoers 内容固定为：

```text
Defaults!/usr/local/libexec/leigod-game-enter env_reset
Defaults!/usr/local/libexec/leigod-game-enter secure_path=/usr/sbin:/usr/bin:/sbin:/bin
%leigod-game ALL=(root) NOPASSWD: /usr/local/libexec/leigod-game-enter *
```

即：不能用这条规则跑任意命令；游戏参数在降权后才 `exec`，不会由 root shell 展开。

卸载默认**保留** `leigod-game` 组，以免脚本改写其他软件依赖的组成员关系。

### 2.3 当前仓库中的持久文件

```text
当前仓库/
├── .leigod/
│   ├── docker.env                         运行配置，0600
│   └── install-manifest                   系统安装文件 SHA-256 清单，0600
├── opt/leigod/
│   ├── acc-gw.router.amd64                本地提供或安装器下载，Git 忽略
│   └── config/ipdatacloud_country.xdb     本地提供或安装器下载，Git 忽略
├── docker/                                Dockerfile、Compose、entrypoint
└── 其余源码和文档
```

安装器不会创建 `/opt/leigod-plugin` 或 `/etc/leigod-plugin`。

### 2.4 宿主前置依赖

`install.sh` 只检查依赖，不调用 apt/dnf/pacman 安装宿主软件：

- Docker Engine 和 Docker Compose v2
- C 编译器 `cc`
- `sudo`、`visudo`、`groupadd`、`usermod`、`getent`
- `curl`、`sha256sum`
- `iproute2` 提供的宿主 `ip` 命令
- 常规 coreutils/文本工具

用途：

- `cc` 只编译 `leigod-netns-exec`。发现代理在 `docker/Dockerfile.discover-proxy` 中静态编译。
- `curl` 只下载缺失的第三方资产；当前实现仍统一检查它是否存在。
- `ip` 只读检测默认接口、网关和子网；安装器不直接修改宿主路由或 iptables。
- Docker daemon 负责创建镜像、容器、macvlan/bridge 以及 Docker 自己的 NAT/filter 规则。

### 2.5 安装器对系统环境的影响

**会改变：**

| 对象 | 影响 |
|---|---|
| `/usr/bin/leigod-game-run` | 新增或覆盖。与发行版同名文件冲突时，若尚无本项目 sudoers，安装器拒绝覆盖。 |
| `/usr/local/libexec/leigod-*` | 新增游戏入口、namespace helper。 |
| `/etc/sudoers.d/leigod-game` | 新增一条 NOPASSWD 规则，范围仅上述 enter helper。 |
| 系统组 `leigod-game` | 可能新建；指定用户被追加进该组。 |
| Docker 镜像 `leigod-plugin:1.2.2.15` | 本地构建；占用 Docker data-root。 |
| Docker 镜像 `leigod-discover-proxy:1.2.2.15` | 仅 bridge：静态开源发现代理。 |
| 容器 `leigod-plugin` | `restart: unless-stopped`，开机由 Docker 拉起。 |
| 容器 `leigod-discover-proxy` | 仅 bridge：`network_mode: host`，非 root，无额外 capability。 |
| Docker 网络 | macvlan：`leigod-plugin-macvlan`（parent 上多一个 MAC/IP）。bridge：`leigod-plugin-bridge`（默认 `172.21.0.0/16`，容器 `172.21.0.2`）。 |
| Docker 卷 `leigod-plugin-state` | 挂载到 `/var/lib/leigod/config`，保留手机绑定配置；不是宿主目录 bind mount。 |
| 宿主监听端口 | macvlan：容器在 LAN 上自己听 5588/TCP、6066/UDP。bridge：Docker 把 5588/TCP 发到 `--bind-address`（默认 `127.0.0.1`）；6066/UDP 由 host-network 发现代理在同一地址上听。调试口 10001/TCP 不发布。 |
| 宿主防火墙 | **不修改。** 手机要从 LAN 访问时，须自行放行 5588/TCP 与 6066/UDP。 |

**不会改变：**

- 宿主默认路由、全局 iptables/nftables、NetworkManager/systemd-networkd 配置
- `/etc/resolv.conf`（游戏只加入 network namespace，继续使用宿主 DNS，例如路由器 `192.168.1.1`）
- 用户 HOME、桌面会话、Lutris 配置（Command prefix 需用户自己填）
- 内核模块（只要求已有 `tun`；macvlan 需内核支持但安装器不 `modprobe`）
- 发行版软件包、时钟、主机名
- 路由器或 DHCP 服务器（macvlan 的 `--ip` 须人工预留）

**运行时、非持久：**

- `/run/user/<UID>/leigod-env.*`：每次 `leigod-game-run` 创建，`0600`，wrapper 退出即删。
- 游戏进程不再创建私有 mount namespace，也不再临时改写 `resolv.conf`（避免 umu/bwrap 无法再次 bind 该文件）。
- 容器内 `/tmp`、`/run` 和 `/var/lib/leigod` 父目录：tmpfs，原始日志、锁、DHCP 租约和网络状态在容器重建后消失。入口把分级、脱敏和重复折叠后的日志转发给 Docker；Docker `json-file` 日志最多保留 3 × 10 MiB。

**Docker 持久状态：** `/var/lib/leigod/config` 由 `leigod-plugin-state` 覆盖，`accelerator.ini` 中的手机绑定 token/user ID 随容器和镜像重建保留。当前入口只复制缺失模板，不校验或清理已有卷内容。

**游戏进程影响：** 通过 prefix 启动的进程进入容器 **network namespace**（出口走加速 TUN），仍是宿主 UID、宿主文件系统、宿主 GPU/音频组。未加 prefix 的 Lutris 主界面和其他程序仍走宿主默认网络。

### 2.6 Docker daemon 侧产物

这些不在 Git 仓库内，由 Docker 管理：

```text
镜像     leigod-plugin:1.2.2.15
         leigod-discover-proxy:1.2.2.15   # 仅 bridge
容器     leigod-plugin
         leigod-discover-proxy            # 仅 bridge，network_mode: host
网络     leigod-plugin-macvlan  或  leigod-plugin-bridge
卷       leigod-plugin-state（手机绑定配置，默认卸载保留）
build cache  以及 Docker 为发布端口写入的 NAT/filter 规则
```

bridge 且 `--bind-address 0.0.0.0` 时，`docker-proxy` 在宿主监听 5588/TCP。6066/UDP **不**由 Docker 发布，而由 host-network 发现代理容器直接 bind，避免 docker-proxy 吃掉广播并把 `ip=172.21.0.2` 通告给手机。

## 3. 容器内容和文件系统边界

镜像以 `debian:bookworm-slim` 为基础，包含：

- `/opt/leigod/acc-gw.router.amd64`
- 雷神配置和 IP 数据库模板
- 项目 `leigod-entrypoint`、`leigod-healthcheck`、`leigod-log-forwarder` 与 `leigod-dns-stub`
- `ca-certificates`、`iproute2`、`ipset`、`iptables`、`procps`

容器不挂载：

- 用户 HOME
- 游戏目录
- Wine prefix
- X11/Wayland socket
- GPU、音频或输入设备
- Docker socket
- 宿主根目录

唯一设备映射是 `/dev/net/tun`；唯一宿主文件 bind mount 是当前仓库中的 `opt/leigod/fake_product_name`，并且为只读。

容器根文件系统只读；`/tmp`、`/run` 和 `/var/lib/leigod` 父目录是 `nosuid,nodev,noexec` tmpfs。其下 `/var/lib/leigod/config` 是独立 Docker named volume，闭源程序对它可写，用于保留绑定配置。该卷不暴露宿主仓库、HOME 或其他宿主路径。

## 4. 构建数据流

```text
当前 Git 仓库（唯一项目 build context）
  ├─ docker/Dockerfile、Dockerfile.discover-proxy、Compose、entrypoint
  ├─ 配置模板和伪装文件
  └─ 本地或下载的第三方资产
          │
          ▼ docker build（context = 当前仓库）
Docker image: leigod-plugin:1.2.2.15
Docker image: leigod-discover-proxy:1.2.2.15   # 仅 bridge
          │
          ▼ docker compose up
Container: leigod-plugin
Container: leigod-discover-proxy               # 仅 bridge
```

实际构建命令等价于：

```bash
docker build \
  --pull \
  --build-arg LEIGOD_VERSION=1.2.2.15 \
  -f docker/Dockerfile \
  -t leigod-plugin:1.2.2.15 \
  .

docker build \
  --pull \
  -f docker/Dockerfile.discover-proxy \
  -t leigod-discover-proxy:1.2.2.15 \
  .
```

`.dockerignore` 排除 Git 元数据、文档、测试、`.leigod` 运行配置和临时编译目录，避免把无关或敏感运行配置发送给 Docker builder。

## 5. 构建和安装

### 5.1 准备第三方资产

仓库不跟踪以下文件：

```text
opt/leigod/acc-gw.router.amd64
opt/leigod/config/ipdatacloud_country.xdb
```

推荐从可信来源取得文件，并通过独立渠道获得 SHA-256：

```bash
sha256sum \
  opt/leigod/acc-gw.router.amd64 \
  opt/leigod/config/ipdatacloud_country.xdb
```

安装器对提供的哈希强制验证。若文件缺失，下载临时文件也创建在当前仓库的随机 `.leigod-build.*` 目录；校验成功后才安装到上述 `opt/leigod` 路径。

缺失资产且没有预期哈希时，默认拒绝旧 HTTP 下载。`--allow-unverified-download` 是显式的不安全兼容开关。

### 5.2 macvlan 安装

从路由器 DHCP 池外预留未占用 IPv4 地址：

```bash
sudo ./install.sh \
  --network macvlan \
  --parent enp3s0 \
  --subnet 192.168.1.0/24 \
  --gateway 192.168.1.1 \
  --ip 192.168.1.240 \
  --user "$USER" \
  --binary-sha256 <ACC_SHA256> \
  --xdb-sha256 <XDB_SHA256>
```

`parent`、`subnet`、`gateway` 可以尝试自动检测；静态 `--ip` 不会自动猜测，以避免和 DHCP 租约冲突。

### 5.3 bridge 回退

无线接口通常不支持额外 macvlan MAC，可显式使用：

```bash
sudo ./install.sh \
  --network bridge \
  --user "$USER" \
  --binary-sha256 <ACC_SHA256> \
  --xdb-sha256 <XDB_SHA256>
```

加速容器仍然不是 host network。Web/API 的 5588/TCP 默认只发布到 `127.0.0.1`；手机需要从同一 Wi-Fi 发现设备时使用 `--bind-address 0.0.0.0`。6066/UDP 不由 Docker 发布，而由 `leigod-discover-proxy` sidecar（host network）监听，避免广播进不了 docker-proxy，并把应答中的 `ip=172.x` 改写成宿主 LAN 地址。程序的 10001/TCP 调试端口不发布。

### 5.4 安装器顺序

1. 检查 root、x86_64、TUN、Docker/Compose 和宿主工具。
2. 验证网络参数、用户名、MAC 和资产哈希。
3. 在当前仓库准备 `.leigod/docker.env` 和缺失资产。
4. 在当前仓库随机临时目录编译 `leigod-netns-exec`。
5. 直接以当前仓库构建 `leigod-plugin` 镜像；bridge 再构建 `leigod-discover-proxy` 镜像（构建阶段运行 `--self-test`）。
6. 使用仓库内 Compose 启动 macvlan 或 bridge 容器并等待 healthy；健康检查要求 TUN、daemon、Web 控制进程和 5588/TCP 监听均正常。bridge 会先 `compose down` 并删除旧 `leigod-plugin-bridge`，以便静态 IPAM 生效，再确认发现代理为 host network、非 privileged。
7. 容器健康后才安装 `/usr/bin/leigod-game-run`、`/usr/local/libexec/leigod-game-enter`、`leigod-netns-exec`，创建 `leigod-game` 组并写入 sudoers。
8. 对全部已安装系统文件生成 `.leigod/install-manifest`。
9. 删除仓库内临时编译目录。

## 6. 运行时调用链

Lutris 单个游戏的 Command prefix：

```text
/usr/bin/leigod-game-run --
```

调用链：

```text
Lutris/Wine（普通用户、宿主 mount/PID namespace）
  │
  ├─ /usr/bin/leigod-game-run
  │    ├─ 把当前环境以 NUL 分隔写入 /run/user/UID 临时文件
  │    └─ sudo -n 调用固定 root helper
  │
  ├─ /usr/local/libexec/leigod-game-enter（root）
  │    ├─ 固定连接宿主 Docker socket
  │    ├─ 验证容器 running + healthy
  │    ├─ 拒绝 privileged、错误网络名
  │    ├─ 要求 cap_drop ALL，且 cap_add 仅为 NET_ADMIN+NET_RAW
  │    │  （同时接受 Docker 返回的 CAP_ 前缀写法）
  │    └─ 取得容器 PID
  │
  └─ /usr/local/libexec/leigod-netns-exec（短暂 root）
       ├─ 进入容器 network namespace
       ├─ 不进入容器 mount namespace，不替换 resolv.conf
       ├─ 设置 no_new_privs，恢复桌面用户真实附加组
       ├─ 永久降到调用者 UID/GID
       └─ 降权后恢复 Lutris/Wine 环境并 exec 游戏
```

共享关系：

| 资源 | 游戏与雷神容器是否共享 |
|---|---|
| network namespace | 是 |
| mount/filesystem namespace | 否 |
| PID namespace | 否 |
| user namespace/UID 身份 | helper 不进入 user namespace；游戏始终保持宿主普通用户 |
| cgroup/容器资源限制 | 否 |
| HOME、游戏目录、Wine prefix | 否；雷神容器不可见 |

## 7. 容器安全配置

关键设置：

```yaml
privileged: false
cap_drop:
  - ALL
cap_add:
  - NET_ADMIN
  - NET_RAW
devices:
  - /dev/net/tun:/dev/net/tun:rwm
security_opt:
  - no-new-privileges:true
read_only: true
```

另外：

- IPv6 在容器 namespace 中关闭，避免绕过仅支持 IPv4 的加速路径。
- 配置了 PID、内存和 CPU 上限。
- 没有 Docker socket、host PID、host IPC 或 privileged。加速容器没有 host network；仅 bridge 发现代理 sidecar 使用 host network。
- 自动升级 monitor 不运行；升级依赖重新校验资产并构建镜像。

## 8. 使用和检查

安装后注销并重新登录一次，使 `leigod-game` 组生效。

直接 Wine 示例：

```bash
/usr/bin/leigod-game-run -- wine /path/to/game.exe
```

检查容器：

```bash
docker inspect leigod-plugin --format \
  'privileged={{.HostConfig.Privileged}} network={{.HostConfig.NetworkMode}} caps={{json .HostConfig.CapAdd}}'
docker logs --tail 100 leigod-plugin
```

闭源程序的 daemon、Web API、游戏核心和 console 日志分别带来源标签转发到 Docker。`--log-level` 接受 `off/error/warn/info/debug`，默认 `warn`；重复消息每 60 条汇总一次，单行最多转发 4096 字符，已知凭据字段始终脱敏。`info/debug` 会暴露更多游戏连接元数据，只应用于短期排障。

检查项目静态安全不变量：

```bash
./tests/security-policy.sh
```

## 9. 卸载

必须从原仓库目录执行：

```bash
sudo ./uninstall.sh
```

该命令删除容器和项目网络，并按 `.leigod/install-manifest` 检查游戏 launcher/helper 和 sudoers。只有清单中存在、仍是普通文件且当前 SHA-256 与安装时一致的固定白名单路径才会删除；修改过、无法验证或变成符号链接的文件会保留，清单也会留下供人工审查。`.leigod/docker.env` 会删除。默认保留本地构建镜像、`opt/leigod` 中的第三方资产以及 `leigod-plugin-state` 手机绑定卷。删除镜像但保留绑定：

```bash
sudo ./uninstall.sh --purge
```

仅在明确希望清除手机绑定时使用：

```bash
sudo ./uninstall.sh --purge-state
sudo ./uninstall.sh --purge --purge-state  # 同时删除镜像和绑定卷
```

`--purge-state` 使用固定卷名，并要求 `com.docker.compose.project=leigod-plugin`、`com.docker.compose.volume=leigod-state` 两个标签同时匹配；否则拒绝删除。普通卸载和单独 `--purge` 都不会删除该卷。

普通卸载后卷不再被容器引用，Docker 会把它视为未使用卷；若计划以后恢复绑定，不要手工 `docker volume rm leigod-plugin-state`，也不要运行会清理未使用卷的 `docker volume prune`。

系统组 `leigod-game` 默认保留，以免卸载脚本擅自重写已有用户组成员关系。

## 10. 已知限制

1. **仓库路径成为部署路径。** 安装后移动或删除仓库会破坏 Compose/DMI 源路径；应先卸载，移动后再安装。
2. **Docker 数据不在仓库内。** 镜像、build cache、容器层、网络状态和 `leigod-plugin-state` 绑定卷位于 Docker data-root，这是 Docker daemon 的固有行为。宿主 root/Docker daemon 可以读取卷中的账号绑定 token。
3. **系统路径可能与其他管理方式冲突。** 当前按部署要求直接安装 `/usr/bin/leigod-game-run`、`/usr/local/libexec/leigod-*` 和 sudoers；安装前应确认没有同名文件。卸载器对这些文件使用安装清单中的 SHA-256，文件被修改或无法确认来源时不会删除。
4. **宿主需要 C 编译器。** 可以以后改用可复现的预编译 helper 或受控 multi-stage 构建，但需要处理 libc 兼容和产物安装。
5. **基础镜像使用可变 tag。** `debian:bookworm-slim` 可以进一步固定 digest 并建立更新流程。
6. **没有真实第三方资产的端到端测试。** 当前验证覆盖 C 编译、shell/sudoers、Compose 渲染、发现代理改写测试和安全策略；真实加速器启动仍需要合法资产及可访问的 Docker daemon。
7. **bridge 手机发现依赖发现代理 sidecar。** 代理容器必须在跑，手机才能扫到设备；绑定之后的 WebSocket 走 5588，不经过代理。`restart: unless-stopped` 由 Docker 在开机后拉起。
8. **安装器不改宿主防火墙。** Docker 监听 `0.0.0.0` 不等于 nftables/firewalld 放行；LAN 访问须另行允许 5588/TCP 与 6066/UDP。
9. **Steam Deck 模式下 `getDeviceList` 在隔离 netns 中通常为空。** 手机仍按路由器插件接口要局域网设备列表；官方说明是绑定后选择「加速电脑游戏」。容器内 `/tmp/dhcp.leases` 种子不一定会被该模式读取。
10. **部分 Docker 版本把 CapAdd 序列化为 `CAP_NET_ADMIN`。** `leigod-game-enter` 须同时接受有无 `CAP_` 前缀，否则 Lutris 会在进网之前被拒绝。
