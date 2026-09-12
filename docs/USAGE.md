# 部署与使用手册

本文面向实际部署者，说明如何在 `macvlan` 与 `bridge` 之间选择、准备参数、执行安装、配置 Lutris、验证运行状态，以及每个脚本在宿主和容器中做了什么。安全边界和残余风险另见 [SECURITY.md](SECURITY.md)，文件安装清单和实现审计另见 [IMPLEMENTATION_REVIEW.md](IMPLEMENTATION_REVIEW.md)。

## 1. 先说明设备 MAC

仓库中发现代理的自测使用示例 MAC，例如 `02:11:22:33:44:55`。它只是一段测试报文，用来验证 `ip=` 字段改写，不参与容器启动、手机发现或绑定。

实际设备 MAC 来自安装时的 `LEIGOD_DEVICE_MAC`：

1. 若调用者显式提供，`install.sh` 校验格式后使用该值。
2. 若未提供，安装器用 `/etc/machine-id`（缺失时用 hostname）和固定字符串计算 SHA-256，生成以 `02:` 开头的本地管理 MAC。
3. 最终值写入仓库内 `.leigod/docker.env`，由 Compose 同时用于 macvlan 或 bridge 接口。
4. 容器入口把承载默认路由的 Docker 接口改名为 `wlan0`，并再次验证其 MAC 与配置一致。

因此，修改自测样本不会改变现有部署。可以用以下命令核对运行值；不要把输出贴到公开 issue：

```bash
sudo sed -n 's/^LEIGOD_DEVICE_MAC=//p' .leigod/docker.env
docker inspect leigod-plugin --format \
  '{{range .NetworkSettings.Networks}}{{.MacAddress}}{{end}}'
```

两处应相同。容器重建继续读取同一个 `.leigod/docker.env`，Docker named volume `leigod-plugin-state` 继续保留手机绑定状态。若迁移到另一台机器且希望手机仍把它识别成同一设备，应安全迁移运行配置和绑定卷，或在安装前显式传入原 MAC；不要把这些内容提交到 Git。

注意：重新执行 `install.sh` 时只从旧配置读取“上一种网络模式”，不会自动继承以前显式指定的自定义 MAC。默认自动生成的 MAC 因 `/etc/machine-id` 不变而保持稳定；若使用自定义 MAC，应在每次安装或模式切换时都传入同一个 `LEIGOD_DEVICE_MAC`。

显式指定 MAC 的形式如下，示例值不可与局域网中的真实设备冲突：

```bash
sudo env LEIGOD_DEVICE_MAC=02:11:22:33:44:55 \
  ./install.sh <其余参数>
```

## 2. 两种网络模式如何选择

| 项目 | macvlan（首选） | bridge（兼容模式） |
|---|---|---|
| 适用环境 | 有线网卡，交换机/AP 允许额外 MAC | Wi-Fi、额外 MAC 被拒绝，或希望使用 Docker NAT |
| LAN 身份 | 容器直接拥有独立 LAN MAC 和静态 IP | 容器使用 Docker 私网地址，默认 `172.21.0.2` |
| 手机发现 | 手机直接发现容器 | host-network 发现代理容器改写通告 IP |
| Web/API 5588 | 容器直接在其 LAN IP 监听 | Docker 发布到宿主 `--bind-address` |
| 宿主到容器 | macvlan 默认不能从 parent 宿主直接访问 | 可通过发布的 5588/TCP 访问 |
| 必须准备 | parent、LAN 子网/网关、DHCP 池外静态 IP | 手机发现时须设置 LAN bind，并自行放行 5588/TCP、6066/UDP |
| 常见失败 | Wi-Fi/AP 不允许一个客户端使用多个 MAC | 防火墙、AP 客户端隔离、Docker 私网与 VPN/现有网段冲突 |

两种模式的加速容器都使用独立 network namespace，都不使用 `privileged`。加速容器本身不使用 `network_mode: host`；只有 bridge 的开源发现代理 sidecar 使用 host network，以便接收局域网 UDP 广播。只有通过 `/usr/bin/leigod-game-run` 启动的游戏进程进入加速 namespace；Lutris 主界面和宿主其他程序仍使用普通网络。

## 3. 共同前置条件

### 3.1 系统依赖

- x86_64 Linux。
- `/dev/net/tun` 可用。
- Docker Engine 与 Docker Compose v2。
- `cc`、`curl`、`iproute2`、`sudo`、`sha256sum`、账户/组管理和常规文本工具。
- 安装时可使用 root；游戏必须由普通桌面用户启动。

检查关键条件：

```bash
uname -m
test -c /dev/net/tun && echo TUN_OK
docker info
docker compose version
```

不要仅为运行游戏把桌面用户加入 `docker` 组。Docker socket 通常等价于宿主 root；本项目改用固定 sudo helper，并在执行游戏前恢复普通用户身份。

本文的 Docker 检查命令假定当前账户已有合法的 Docker 管理权限；若没有，应在这些管理命令前使用 `sudo`，而不是仅为方便把账户加入 `docker` 组。Lutris 启动游戏时不直接调用 Docker，由受限 sudo helper 完成必要检查。

### 3.2 仓库和官方资产

安装必须从最终保留的仓库目录执行。Compose 和只读 DMI 文件引用这个目录，安装后不要直接移动或删除仓库。

需要以下两个不进入 Git 的第三方文件：

```text
opt/leigod/acc-gw.router.amd64
opt/leigod/config/ipdatacloud_country.xdb
```

推荐从可信渠道取得，并传入独立获得的 SHA-256：

```bash
sha256sum opt/leigod/acc-gw.router.amd64 \
  opt/leigod/config/ipdatacloud_country.xdb
```

若文件已在上述位置，即使暂时不传哈希，安装器也会使用本地文件并打印“未独立验证”警告。若文件缺失、又没有预期哈希，只有显式添加 `--allow-unverified-download` 才会从旧 HTTP 地址下载；该开关不能证明下载内容可信。

### 3.3 用户和日志参数

- `--user "$USER"`：授权当前桌面用户。通过 sudo 调用时，shell 会先展开 `$USER`。
- `--log-level off|error|warn|info|debug`：默认 `warn`。`info/debug` 可能包含游戏域名、IP 或闭源程序未识别的敏感字段，只适合短期排障。

### 3.4 安装参数速查

| 参数 | 模式 | 说明 |
|---|---|---|
| `--network macvlan|bridge` | 两者 | 默认 macvlan |
| `--parent INTERFACE` | macvlan | 物理 parent；未给出时尝试从默认路由检测 |
| `--subnet CIDR` | macvlan | LAN 子网；未给出时尝试读取直连路由 |
| `--gateway ADDRESS` | macvlan | LAN 网关；未给出时尝试读取默认路由 |
| `--ip ADDRESS` | macvlan | 容器静态 LAN IP，必填且必须在 DHCP 池外预留 |
| `--bind-address ADDRESS` | bridge | 5588/TCP 和发现代理的宿主监听地址；默认 `127.0.0.1` |
| `--user USER` | 两者 | 获准使用 wrapper 的普通桌面用户 |
| `--log-level LEVEL` | 两者 | Docker 日志详细度，默认 `warn` |
| `--binary-sha256 HASH` | 两者 | 闭源加速器的预期 SHA-256 |
| `--xdb-sha256 HASH` | 两者 | IP 数据库的预期 SHA-256 |
| `--allow-unverified-download` | 两者 | 允许缺失资产在无预期哈希时从旧 HTTP 地址下载 |

安装器也读取同名环境配置，例如 `LEIGOD_DEVICE_MAC`、`LEIGOD_BRIDGE_SUBNET`、`LEIGOD_BRIDGE_GATEWAY` 和 `LEIGOD_BRIDGE_IPV4`。`config/docker.env.example` 仅供审查字段；正常安装应由脚本生成 `.leigod/docker.env`，不要把账号数据手工写入示例文件。

## 4. macvlan 部署

### 4.1 准备网络参数

查看默认接口、网关和直连子网：

```bash
ip -4 route show default
ip -4 route show proto kernel scope link
```

假设结果对应：

```text
parent:  enp3s0
subnet:  192.168.1.0/24
gateway: 192.168.1.1
```

还必须从路由器 DHCP 地址池之外预留一个未占用地址，例如 `192.168.1.240`。安装器不会自动猜测这个地址，也不会改路由器 DHCP 配置。应优先在路由器侧确认地址没有被分配，而不是只依赖一次 `ping`。

### 4.2 安装命令

完整、推荐的命令：

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

安装器通常可以自动读取 parent、subnet 和 gateway，因此最短形式是：

```bash
sudo ./install.sh \
  --network macvlan \
  --ip 192.168.1.240 \
  --user "$USER" \
  --binary-sha256 <ACC_SHA256> \
  --xdb-sha256 <XDB_SHA256>
```

本地资产已准备、暂时不做哈希验证时，省略两个哈希参数即可。若资产缺失且仍要使用旧下载地址，则必须额外添加 `--allow-unverified-download`。

### 4.3 macvlan 的预期行为

- 创建 Docker 网络 `leigod-plugin-macvlan`。
- 容器使用预留的 LAN IP 和稳定 MAC，直接与网关及手机通信。
- 不启动发现代理 sidecar；若当前 Compose 项目里还有该容器，`--remove-orphans` 会去掉它。
- 不发布 Docker host port。
- 同一 parent 上的宿主默认不能直接访问 macvlan 容器，这是 macvlan 的正常隔离行为；游戏通过 `setns` 进入容器网络，不依赖宿主访问容器 IP。

若 parent 是 Wi-Fi，安装器会给出警告。出现容器无法联网、接口创建失败或 AP 拒绝额外 MAC 时，改用 bridge。

### 4.4 验证 macvlan

```bash
docker inspect leigod-plugin --format \
  'health={{.State.Health.Status}} privileged={{.HostConfig.Privileged}} network={{.HostConfig.NetworkMode}} caps={{json .HostConfig.CapAdd}}'
docker network inspect leigod-plugin-macvlan --format \
  'driver={{.Driver}} parent={{index .Options "parent"}}'
docker logs --tail 100 leigod-plugin
```

预期看到 `healthy`、`privileged=false`、网络名 `leigod-plugin-macvlan`，capability 只有 `NET_ADMIN` 和 `NET_RAW`。手机与容器位于同一可互访 LAN 时，应能直接扫描到 Steam Deck 设备。

## 5. bridge 部署

### 5.1 本机访问与手机发现的区别

bridge 默认把 5588/TCP 绑定到 `127.0.0.1`。这只适合本机访问，手机不能连接 loopback，也通常收不到绑定在 loopback 的发现代理。

手机需要在同一可信 Wi-Fi 中发现和绑定时，使用：

```bash
sudo ./install.sh \
  --network bridge \
  --bind-address 0.0.0.0 \
  --user "$USER" \
  --binary-sha256 <ACC_SHA256> \
  --xdb-sha256 <XDB_SHA256>
```

本地资产已准备、暂时不做哈希验证时可以省略两个哈希参数；资产缺失且仍要下载时添加 `--allow-unverified-download`。

`0.0.0.0` 会让 5588/TCP 和发现代理的 6066/UDP 在所有 IPv4 接口监听。发现代理与宿主共用网络命名空间，但不把 6066 交给 docker-proxy 发布。安装器不会修改宿主防火墙；应只允许可信 LAN 源网段访问：

| 端口 | 协议 | 用途 |
|---|---|---|
| 5588 | TCP | 手机 App 与闭源 Web/API 进程通信 |
| 6066 | UDP | 手机发现请求，由 host-network 发现代理容器接收 |

不要向公网端口转发这两个端口。不同发行版使用 nftables、firewalld 或 ufw，具体规则应按本机现有防火墙管理方式添加，并限制来源为可信 LAN。

### 5.2 Docker 私网冲突

bridge 默认值为：

```text
subnet:    172.21.0.0/16
gateway:   172.21.0.1
container: 172.21.0.2
```

若该网段与 VPN、公司网络或已有 Docker 网络冲突，可通过环境变量覆盖；三项必须彼此一致：

```bash
sudo env \
  LEIGOD_BRIDGE_SUBNET=172.30.0.0/16 \
  LEIGOD_BRIDGE_GATEWAY=172.30.0.1 \
  LEIGOD_BRIDGE_IPV4=172.30.0.2 \
  ./install.sh \
    --network bridge \
    --bind-address 0.0.0.0 \
    --user "$USER" \
    --binary-sha256 <ACC_SHA256> \
    --xdb-sha256 <XDB_SHA256>
```

安装器会先停止旧 bridge Compose 项目并删除旧 `leigod-plugin-bridge` 网络，再用固定 IPAM 重建，避免旧子网参数残留。不会删除 `leigod-plugin-state`。

### 5.3 bridge 发现代理如何工作

闭源程序在容器内会把 Docker 私网 IP 写入发现应答，手机无法直接连接该地址。因此 bridge 安装会构建 `leigod-discover-proxy` 镜像并启动 sidecar（`network_mode: host`）：

1. sidecar 与宿主共用网络命名空间，在 `--bind-address:6066/UDP` 等待手机广播或单播。
2. 它取得接收报文的宿主本地 IPv4；使用 `0.0.0.0` 时依靠 `IP_PKTINFO` 区分实际收到报文的接口地址。
3. 它把最多 2048 字节的请求转发到固定 bridge 容器 IP 的 6066/UDP。
4. 最多等待 400 ms 获取容器应答。
5. 仅把应答中的 `ip=` 值替换为宿主收到请求的 LAN 地址；`model=`、`sn=`/MAC、`bound=` 等字段保持容器原值。
6. 它从同一个宿主 LAN 地址把改写后的应答发回手机。

因此，源码自测里的示例 MAC 不可能替换实际发现应答中的 MAC。代理只改 `ip=`。

该 sidecar 使用 `cap_drop: ALL`、只读根文件系统、`no-new-privileges`、非 root `65534:65534`，以及 32M 内存 / 16 PID 上限。6066/UDP 不经 docker-proxy 发布。雷神闭源二进制仍只在加速容器内，加速容器本身仍不使用 host network。安装器不再把发现代理写入 `/usr` 或 `/etc/systemd`。

### 5.4 验证 bridge

```bash
docker inspect leigod-plugin --format \
  'health={{.State.Health.Status}} privileged={{.HostConfig.Privileged}} network={{.HostConfig.NetworkMode}} caps={{json .HostConfig.CapAdd}}'
docker network inspect leigod-plugin-bridge --format 'driver={{.Driver}}'
docker inspect leigod-discover-proxy --format \
  'running={{.State.Running}} network={{.HostConfig.NetworkMode}} privileged={{.HostConfig.Privileged}} user={{.Config.User}}'
docker logs --tail 100 leigod-plugin
docker logs --tail 50 leigod-discover-proxy
```

预期加速容器为 `healthy`，网络名是 `leigod-plugin-bridge`；发现代理为 `running`、`network=host`、`privileged=false`、`user=65534:65534`。

可从宿主 loopback 验证改写流程，同时避免打印完整序列号：

```bash
python3 - <<'PY'
import socket

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(2)
s.sendto(b"<NBOX> HELLO", ("127.0.0.1", 6066))
reply = s.recv(4096).decode("utf-8", "replace")
fields = {}
if "(" in reply and ")" in reply:
    for item in reply.split("(", 1)[1].rsplit(")", 1)[0].split(", "):
        if "=" in item:
            key, value = item.split("=", 1)
            fields[key] = value
print("model=%s bound=%s ip=%s" %
      (fields.get("model"), fields.get("bound"), fields.get("ip")))
PY
```

手机仍发现不到时依次检查：容器健康、安装参数是否为 `--bind-address 0.0.0.0`、发现代理容器、宿主 6066/UDP 与 5588/TCP 防火墙、手机与宿主是否处于同一 LAN，以及 AP 是否开启客户端隔离。

## 6. 手机绑定与 Lutris 使用

安装完成后先注销并重新登录桌面会话，使 `leigod-game` 附加组生效：

```bash
id -nG | tr ' ' '\n' | grep -x leigod-game
```

然后：

1. 在手机 App 中扫描并绑定 Steam Deck 设备。
2. 在 App 中选择需要加速的电脑游戏并启动加速。
3. 在 Lutris 对应游戏的 Runner/System options 中，把 **Command prefix** 设置为：

```text
/usr/bin/leigod-game-run --
```

Lutris 会把实际 runner 命令追加在 `--` 后面。只有 Wine/游戏进程树进入加速 network namespace，Lutris UI 保持宿主网络。

直接运行 Wine 的形式：

```bash
/usr/bin/leigod-game-run -- wine /path/to/game.exe
```

短期诊断也可以运行：

```bash
/usr/bin/leigod-game-run -- lutris
```

但这会让整个 Lutris 进程树进入加速网络，不是日常推荐配置。本项目当前不自动操作手机端的开始/暂停状态；加速器启停仍由 App 控制。

## 7. 游戏 wrapper 的实际调用链

### 7.1 `bin/leigod-game-run`

安装到 `/usr/bin/leigod-game-run`，以桌面用户运行：

1. 接受可选的第一个 `--`，并拒绝空命令。
2. 要求 `/run/user/<UID>` 存在且属于调用用户。
3. 用 `umask 077` 创建 `leigod-env.*`，通过 `env -0` 保存完整、NUL 分隔的 Lutris/Wine 环境。
4. 使用 `sudo -n` 调用固定的 `/usr/local/libexec/leigod-game-enter`；不会弹出密码窗口。
5. wrapper 退出时删除临时环境文件。

### 7.2 `libexec/leigod-game-enter`

这是 sudoers 唯一允许无密码运行的 root shell helper：

1. 重置 PATH、locale、HOME，清除 loader、语言运行时和 Docker 相关危险环境变量。
2. 验证 sudo 调用者 UID/GID、环境文件路径和命令分隔符。
3. 使用固定 Docker socket、固定容器名 `leigod-plugin` 执行 `docker inspect`。
4. 要求容器 running、healthy、非 privileged、属于 `leigod-plugin` Compose 项目。
5. 只接受 `leigod-plugin-macvlan` 或 `leigod-plugin-bridge`，并要求 `cap_drop=ALL`、`cap_add` 仅为 `NET_ADMIN`/`NET_RAW`。
6. 取得并验证容器 PID 后，`exec` 固定的 C helper；用户命令不会被 root shell 展开。

### 7.3 `src/leigod-netns-exec.c`

现场编译并以 `0700` 安装，只由上一层调用：

1. 解析 PID/UID/GID，拒绝 PID ≤ 1 或 root 目标用户。
2. 为桌面用户恢复真实附加组，保留 GPU、音频等设备权限。
3. 用 `O_NOFOLLOW` 打开环境文件，要求它是调用用户拥有、组/其他人无权限、最大 1 MiB 的普通文件。
4. 打开 `/proc/<container-pid>/ns/net` 并只执行 `setns(..., CLONE_NEWNET)`。
5. 不进入容器 mount、PID 或 user namespace，也不替换 `/etc/resolv.conf`。
6. 设置 `no_new_privs`、清空 ambient capability、永久降至桌面 UID/GID。
7. 降权后恢复环境并 `execvp` 游戏命令。

游戏因此使用宿主文件系统、HOME、Wine prefix、GPU 和音频，但网络路由/TUN 与闭源加速器相同。若宿主 `/etc/resolv.conf` 只指向 loopback DNS stub，进入另一 network namespace 后可能无法访问该 stub；DNS 故障时应先检查其中是否有可从该 namespace 到达的上游 DNS 地址。

## 8. 容器脚本逻辑

### 8.1 `docker/entrypoint.sh`

1. 要求 `/dev/net/tun`、可执行闭源程序和只读 DMI product name `Jupiter`。
2. 把镜像模板中缺失的配置复制到 `/var/lib/leigod/config`。该目录由 named volume 覆盖；现有文件不会在启动时被校验、覆盖或清理。
3. 找到承载默认路由的 Docker 接口，必要时改名为 `wlan0`，验证稳定 MAC，并恢复默认路由。
4. 在容器 tmpfs 中生成 DHCP lease 种子，让闭源程序看到 Steam Deck/Windows PC 设备条目。
5. 启动日志转发器，再用 `daemon + tun + 5588` 参数启动闭源程序。
6. 每 5 秒检查 daemon；退出后重启。日志转发器退出时也会重启。
7. 收到停止信号时先终止闭源 daemon 和日志转发器。

### 8.2 `docker/healthcheck.sh`

容器只有同时满足以下条件才是 healthy：

- `/dev/net/tun` 是字符设备。
- daemon 进程存在。
- Web API 进程存在。
- 5588/TCP 正在监听。

### 8.3 `docker/log-forwarder.sh`

- 跟随 `acc_daemon.log`、`acc_PC.log`、`web_api.log` 和 console，标为 `daemon/game/web/console`。
- 根据 `LEIGOD_LOG_LEVEL` 过滤，默认 `warn`。
- 对已知 token、nonce、user ID、authorization、cookie、password、`speedSign` 和敏感 URL 参数脱敏。
- 单行最多输出 4096 字符；相邻相同消息每 60 条汇总一次。
- Docker `json-file` 日志最多 3 个文件、每个 10 MiB。

脱敏规则只能覆盖已知格式。`info/debug` 日志仍按敏感数据处理，不应直接上传公开平台。

## 9. `install.sh` 的完整逻辑

安装器需要 root，但不会直接修改宿主默认路由、全局 iptables/nftables 或 `/etc/resolv.conf`：

1. 解析参数，检查 root、x86_64、TUN、Docker/Compose 和宿主工具。
2. 拒绝占用同名容器的其他 Compose 项目。
3. 验证网络、日志级别、桌面用户和 MAC；macvlan 自动检测部分 LAN 参数，但强制要求静态 `--ip`。
4. 准备第三方资产：本地文件优先；有预期哈希时强制匹配；无文件、无哈希时只有显式不安全开关才能下载。
5. 在仓库内创建 `.leigod/docker.env`（`0600`），记录网络、稳定 MAC、用户、日志级别和 wrapper 哈希。账号绑定 token 不写在这里。
6. 在仓库内随机 `.leigod-build.*` 临时目录编译 namespace helper。
7. 以当前仓库为唯一 build context 构建 `leigod-plugin:1.2.2.15`；bridge 再构建 `leigod-discover-proxy:1.2.2.15`。
8. 选择相应 Compose override 启动容器，并最多等待约 40 秒成为 healthy。bridge 还会确认发现代理容器为 running、host network、非 privileged。
9. 容器健康后才安装 launcher/helper、创建 `leigod-game` 组、追加桌面用户并校验/安装 sudoers。
10. 对固定系统文件计算 SHA-256，保存到 `.leigod/install-manifest`（`0600`），最后删除临时构建目录。

安装会写入的系统位置仅包括：

```text
/usr/bin/leigod-game-run
/usr/local/libexec/leigod-game-enter
/usr/local/libexec/leigod-netns-exec
/etc/sudoers.d/leigod-game
```

## 10. 日常管理、更新与模式切换

查看状态和日志：

```bash
docker inspect leigod-plugin --format \
  'status={{.State.Status}} health={{.State.Health.Status}} network={{.HostConfig.NetworkMode}}'
docker logs -f --tail 100 leigod-plugin
```

bridge 额外查看：

```bash
docker inspect leigod-discover-proxy --format \
  'running={{.State.Running}} network={{.HostConfig.NetworkMode}} user={{.Config.User}}'
docker logs --tail 100 leigod-discover-proxy
```

更新源码或切换网络模式时，从原仓库目录重新执行完整 `install.sh` 命令。安装器会读取旧 `.leigod/docker.env` 判断原模式、构建新镜像并重建必要组件。命名卷 `leigod-plugin-state` 不会因为正常重装或模式切换而删除。

持久/非持久数据：

| 数据 | 位置 | 重建容器后 |
|---|---|---|
| 网络和安装参数 | `.leigod/docker.env`，0600 | 保留 |
| 系统文件校验清单 | `.leigod/install-manifest`，0600 | 保留 |
| 手机绑定 token/user ID | Docker volume `leigod-plugin-state` | 保留 |
| 原始运行日志、锁、租约 | 容器 tmpfs | 丢失 |
| Docker 转发日志 | Docker data-root，3 × 10 MiB | 按日志驱动管理 |

不要把 `.leigod`、绑定卷导出或 `docker logs` 的详细输出提交到公开仓库。不要运行会误删未使用绑定卷的 `docker volume prune`。

## 11. `uninstall.sh` 的逻辑和选项

卸载必须从原仓库目录执行：

```bash
sudo ./uninstall.sh
```

脚本会读取 `.leigod/docker.env` 选择 Compose override，停止容器和项目网络；随后只删除清单中存在、仍为普通非符号链接、且 SHA-256 未改变的系统文件。被修改、来源无法验证或变成符号链接的文件会保留并报警。

| 命令 | 镜像 | 手机绑定卷 |
|---|---|---|
| `sudo ./uninstall.sh` | 保留 | 保留 |
| `sudo ./uninstall.sh --purge` | 删除 | 保留 |
| `sudo ./uninstall.sh --purge-state` | 保留 | 删除 |
| `sudo ./uninstall.sh --purge --purge-state` | 删除 | 删除 |

删除绑定卷前，脚本要求固定名称 `leigod-plugin-state`，并同时验证 Compose project/volume 标签；不匹配就拒绝删除。第三方资产和 `leigod-game` 系统组始终保留。

## 12. 常见故障定位

### 容器 unhealthy

```bash
docker inspect leigod-plugin --format '{{json .State.Health}}'
docker logs --tail 200 leigod-plugin
```

重点检查 TUN、daemon/Web 子进程和 5588 监听。

### wrapper 提示组权限或容器不可用

```bash
id -nG | tr ' ' '\n' | grep -x leigod-game
docker inspect leigod-plugin --format '{{.State.Health.Status}}'
```

刚安装时应注销并重新登录，而不是只重启 Lutris。

### bridge 手机看不到设备

检查 `--bind-address 0.0.0.0`、发现代理容器、6066/UDP、5588/TCP、同一 LAN 和 AP 客户端隔离。`docker logs leigod-discover-proxy` 中的 timeout 表示请求已到宿主网络命名空间，但加速容器 6066 没有在 400 ms 内应答。

### macvlan 容器不通

确认 parent 名称、预留 IP、子网/网关、地址冲突，以及网卡/AP 是否允许额外 MAC。Wi-Fi 上优先切换到 bridge。

### 游戏能启动但域名解析失败

游戏只进入 network namespace，仍读取宿主 `/etc/resolv.conf`。若其中只写 `127.0.0.1` 或 `127.0.0.53`，该地址在新 namespace 中不是宿主 DNS 服务；应按发行版网络方案提供可路由的上游 DNS。
