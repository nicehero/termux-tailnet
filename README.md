# Termux Tailnet

在 Android 的 **Termux** 中以**无 root、用户态网络**方式加入 Tailscale 兼容的虚拟网络。

项目自带所需二进制与脚本，部署时不需要再从网络下载；控制服务器地址、认证密钥、网段、主机名等全部作为参数传入。仓库内不包含任何控制面地址或密钥。

## 能力

- 用户态 `tailscaled`，不创建 TUN，不需要 root
- runit 服务：Termux 会话在时自动运行，进程崩溃自动重启
- 本机 SOCKS5 / HTTP 代理，供 Termux 内其他程序使用
- `tailscale serve` 把手机端口暴露给虚拟网络
- Termux 内普通 `ssh` / `scp` 通过 tailnet 出站
- 一键部署脚本，支持从 PC 通过 SSH 推送到手机

## 背景

Android 11+ 对普通 App 禁止 `NETLINK_ROUTE`，原版 `tailscaled` 会以
`netlinkrib: permission denied` 退出。官方 Tailscale 1.104+ 内置
`feature/androidbin` 与 `feature/androiddns`，可以在 Termux 的非 root 用户态运行。

本项目附带官方 Tailscale 1.104.2 包，以及一个仅含两处兼容补丁的
`tailscaled-v2`：

1. **DNS**：让 `dnscache` 使用 `net.DefaultResolver`，从而走 Android
   `dnsproxyd`（`/etc/resolv.conf` 在 Android 上不存在）。
2. **Peer 地址**：部分控制面只在 `AllowedIPs` 下发 peer IP，`Addresses` 为空；
   补丁从单主机 `AllowedIPs` 回填 `Addresses`。

另附一个**可选、未应用**的补丁，用于让 `tailscale status` 识别非
`100.64.0.0/10` 的自定义网段（见 `patches/README.md`）。

## 目录

```
bin/tailscaled-v2                  预编译补丁版 daemon（linux/arm64）
vendor/tailscale_1.104.2_arm64.tgz 官方 CLI + daemon
vendor/tailscale-1.104.2-src.tar.gz 官方源码（用于重建）
patches/                           补丁与重建说明
termux/ts-nc                       SSH ProxyCommand 包装
termux/service/                    runit 服务文件
install-termux.sh                  在手机上安装/更新（不联网）
deploy-termux.sh                   从 PC 推送并安装
```

## 快速开始

### 1. 准备认证密钥（在手机上）

```bash
mkdir -p ~/.tailscale
cat > ~/.tailscale/authkey
# 粘贴预授权密钥，Ctrl-D 结束
chmod 600 ~/.tailscale/authkey
```

也可以把已有的密钥文件 `scp` 到 `~/.tailscale/authkey`。

### 2. 部署

**从 PC（推荐）**，前提是 PC 已能通过 SSH 访问手机（示例别名 `termux`）：

```bash
TERMUX_SSH=termux \
CONTROL_URL=https://control.example.com \
TAILNET_CIDR=10.10.0.0/24 \
NODE_HOSTNAME=termux-phone \
bash deploy-termux.sh
```

**或者把项目复制到手机后，在 Termux 中执行**：

```bash
CONTROL_URL=https://control.example.com \
TAILNET_CIDR=10.10.0.0/24 \
NODE_HOSTNAME=termux-phone \
bash install-termux.sh
```

首次登录需要 `CONTROL_URL` 和认证密钥；已经登录过的节点不需要重复登录。

### 3. 验证

```bash
SVDIR=$PREFIX/var/service sv status tailnet

T=~/tailscale/tailscale
S=$TMPDIR/tailscaled.sock
PATH= $T --socket=$S ip
PATH= $T --socket=$S status
PATH= $T --socket=$S ping <peer-ip>
```

> `tailscale` CLI 必须以空 `PATH` 运行：Go 的 `faccessat2` 会被 Android seccomp
> 以 SIGSYS 杀掉。`PATH= ...` 或项目自带的 `~/ts-nc` 已处理这一点。

## 参数

| 变量 | 默认值 | 说明 |
|---|---|---|
| `CONTROL_URL` | 无 | Tailscale 兼容控制服务器地址，如 `https://control.example.com` |
| `AUTH_KEY_FILE` | `~/.tailscale/authkey` | 认证密钥文件路径 |
| `AUTH_KEY` | 无 | 直接传入密钥（写入文件；会出现在环境/历史中，慎用） |
| `NODE_HOSTNAME` | `termux` | 在虚拟网络中显示的节点名 |
| `TAILNET_CIDR` | 无 | 虚拟网络网段，用于生成 SSH 的 `Host` 通配符，如 `10.10.0.0/24` |
| `TAILNET_SSH_GLOB` | 由 CIDR 推导 | 直接指定 SSH 通配符，如 `10.10.0.*` |
| `SSH_PORT` | `8022` | 通过 `tailscale serve` 暴露的本地/尾网端口；`0` 表示关闭 |
| `SOCKS5_LISTEN` | `127.0.0.1:1055` | SOCKS5 监听地址 |
| `HTTP_PROXY_LISTEN` | `127.0.0.1:1056` | HTTP 代理监听地址 |
| `ACCEPT_DNS` | `false` | 是否接受控制面下发的 DNS |
| `ACCEPT_ROUTES` | `false` | 是否接受子网路由 |
| `SVCNAME` | 自动检测 / `tailnet` | runit 服务名 |
| `TAILNET_RESTART` | `0` | 为 `1` 时更新后重启已运行的服务（会断开当前 tailnet SSH） |
| `TERMUX_SSH` | `termux` | 仅 `deploy-termux.sh`：SSH 目标别名或 `user@host` |

## 使用

### 代理

```bash
# SOCKS5
curl --socks5-hostname 127.0.0.1:1055 http://<peer-ip>:<port>/

# HTTP
curl -x http://127.0.0.1:1056 http://<peer-ip>:<port>/
```

只有显式走代理的程序才会进入虚拟网络。

### 入站：虚拟网络 → 手机端口

部署时默认执行：

```bash
PATH= ~/tailscale/tailscale --socket=$TMPDIR/tailscaled.sock \
  serve --bg --tcp 8022 tcp://localhost:8022
```

其他设备即可访问 `<node-ip>:8022`。其他端口同理；配置会持久化。

### 出站：Termux 内 ssh/scp

`install-termux.sh` 会根据 `TAILNET_CIDR` / `TAILNET_SSH_GLOB` 写入
`~/.ssh/config`：

```
Host 10.10.0.*
    ProxyCommand /data/data/com.termux/files/home/ts-nc %h %p
```

之后直接：

```bash
ssh -p 22 user@10.10.0.5
scp file user@10.10.0.5:
```

### 手机其他 App → Termux 端口

Android 的 loopback 在所有 App 间共享：Termux 监听 `127.0.0.1:<port>`（或
`0.0.0.0:<port>`），其他 App 直接连 `127.0.0.1:<port>`。对方需要 `INTERNET`
权限。

## 已知限制

- **不支持系统 ICMP**：用户态网络没有 TUN，`ping` 永远不会通。使用
  `tailscale ping <IP>` 或 TCP 探测。
- 若虚拟网络使用非 `100.64.0.0/10` 网段，`tailscale status` 的 peer IP 列可能为空；
  数据面不受影响。可应用 `patches/optional-0003` 重新构建。
- MagicDNS 取决于控制服务器配置，不能保证可用；建议直接用 IP。
- 服务只在 Termux 存活期间运行；手机重启后需手动打开 Termux。未做开机自启。
- Android 可能杀后台 Termux；部署脚本会执行 `termux-wake-lock`，建议把 Termux
  电池优化设为“无限制”。

## 安全

- SOCKS5/HTTP 代理监听回环且无认证。Android 回环不按 App 隔离，任何有网络权限的
  App 都能访问。敏感环境请自行加认证，且不要绑定 `0.0.0.0`。
- `tailscale serve` 默认仅 tailnet 可见，不是公网 Funnel。
- 认证密钥只保存在手机 `~/.tailscale/authkey`（600）。仓库不包含密钥，也不应提交
  任何密钥文件。

## 重建

见 `patches/README.md`。需要 Go 1.27.x；官方包与源码已包含在 `vendor/`。
