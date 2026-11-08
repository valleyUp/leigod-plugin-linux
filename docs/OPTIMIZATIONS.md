# 安装与运行维护优化

本项目保持一个加速 namespace：进入它的 Steam（含 steamwebhelper）、Ubisoft 和游戏统一交由雷神处理；正常停止加速后，公网业务连接全部直连，Steam Community 也直连。雷神节点的外层连接与控制、发现和 DNS 上游继续绕过宿主 sing-box。不会增加社区代理入口或第二套 TUN 接管规则。

## 安装与升级

`install.sh` 把旧 `.leigod/docker.env` 当作数据读取，不用 `source` 或 `eval` 执行。保留网络模式、绑定地址、两种网络的地址参数、设备 MAC、桌面用户、日志级别、debug 和预期资产哈希；命令行优先于环境变量，环境变量优先于旧值，缺少旧值才采用默认值。`--allow-unverified-download` 每次仍需显式传入。

```bash
sudo ./install.sh --show-config
# 先退出 Steam、Ubisoft、游戏，再升级：
sudo ./install.sh
```

配置先写入私有临时目录供 Compose 使用。编译和两个镜像构建完成后才部署；构建失败不会停止旧项目或覆盖保存配置。部署和宿主安装成功后，用同目录临时文件原子替换 `.leigod/docker.env`，权限保持 `0600`。部署已开始之后的失败不等于旧容器自动恢复，应依据报错检查当前运行状态。

网络驱动、子网、网关和必要驱动选项一致时保留原 Docker 网络。网络参数变化或模式切换才停止旧项目、重建网络。相同 bridge 子网的路由保护保持启用，不会在普通重装时先移除再添加。

保留网络不能保留被重建容器的 namespace。安装器比较镜像 ID 和 Compose 服务配置 hash，在可能替换 namespace 时检查其中的宿主应用，列出 PID/名称并拒绝继续，直到用户退出这些进程。新启动的 Steam/游戏才会加入新容器；开关加速本身通常不要求重启应用，但已有连接可能需要重连。

## 服务健康与加速诊断

Docker 健康检查要求 TUN 字符设备、daemon/Web 进程、5588/TCP，以及本地 DNS 的 UDP/TCP 监听。未开启加速仍应 healthy。Web 进程持续缺失约 20 秒时，入口退出，由 Docker 的重启策略恢复服务；DNS 和日志进程退出时入口单独重启它们。bridge 发现代理在加速容器健康后启动。

```bash
docker exec leigod-plugin /usr/local/sbin/leigod-status --json --sample-seconds 5
```

| 状态 | 含义 |
|---|---|
| `idle` | 服务正常，未开启加速且无残留接管规则 |
| `capture_ready` | 加速进程、tun_PC、mark 0x102、表 102 默认路由和 OUTPUT 标记齐备 |
| `capture_incomplete` | 加速进程存在，但接管条件不完整，可能正在切换或发生故障 |
| `residual_capture` | 加速进程已退出，但接管路由或标记仍存在 |
| `service_unhealthy` | 服务健康条件不完整 |
| `inspection_incomplete` | 无法读取 iptables，无法完成诊断 |

诊断还输出采样期间 TUN 字节、包、错误与丢包增量；不打印绑定 token、账号配置或游戏连接内容。`idle` 和 `capture_ready` 返回 0，其余诊断状态返回 1，采集错误返回 2。`capture_ready` 与计数增长不能独立证明某个游戏已由节点转发；仍需把该游戏 socket 与 `acc_PC.log` 中的目标和 `is_acc(1)` 对应。

## DNS 与发现

- DNS 使用连接到固定上游的 UDP socket，校验事务 ID、QR/opcode 和问题字段，支持有界的 DNS 名称压缩解析；错误回复不会被转发给应用。
- UDP 截断回复会重试同一个上游的 TCP；TCP 客户端使用 TCP 上游。上游超时会尝试下一个服务器，全部失败返回 SERVFAIL。UDP 回包遵守客户端的传统/EDNS 大小限制，过大的答案保留 TC，由客户端重试 TCP。
- DNS 使用 4 个固定线程和最多 32 个排队请求，避免一个查询超时阻塞全部请求，也避免无限创建进程/线程。它仍是转发 stub，不添加 DNS 缓存。
- discovery 只转发 `<NBOX> HELLO`，只接受指定容器地址和端口的 `<NBOX> WHO` 回包，继续仅改写 `ip=`。
- 每个 discovery 请求使用独立的连接 UDP socket，最多同时处理 16 个请求，每个等待 400 ms；超时关闭，迟到回复不会留在共享 socket 中影响下一请求。超时日志按 60 秒汇总。

## 日志

四个日志由一个 Python 标准库进程读取，取消多组 shell/tail/sed 管道。支持改名轮转、截断、部分行和超长行；不主动改动闭源程序持有的日志文件。按来源和移除时间戳后的消息内容汇总重复日志，窗口 60 秒，最多保留 1024 个指纹。脱敏在输出截断前进行，原始超长行直接丢弃，单行输出最多 4096 字符。

容器增加 Python 3 运行时；宿主 macvlan 安装不新增 Python 要求，bridge 仍使用已有 Python 3 路由保护。原始日志仍在 tmpfs，Docker stdout 日志仍按 3 × 10 MiB 轮转；未知凭据格式仍可能需要补充脱敏规则。

## 回归验证

```bash
python3 tests/runtime-helpers.py
python3 tests/network-helpers.py
sh tests/security-policy.sh
sh tests/discover-proxy.sh
# 构建两个 optimization-check 镜像后，可在独立 bridge 网络验证容器启动：
sh tests/container-smoke.sh
```

网络测试只使用 loopback 临时端口和模拟上游，覆盖错来源、错事务 ID、错问题、TCP 回退、UDP 长度、超时/failover、并发、发现报文过滤和迟到回复隔离。运行维护测试覆盖参数优先级、安全读取、网络复用、日志脱敏/轮转和加速诊断状态。

容器启动测试使用临时状态和单独网络，不发布端口，不挂载现有绑定卷；闭源 Web 模块冷启动需要访问雷神全局配置接口，所以这个测试需要联网。测试结束自动删除临时容器和网络。
