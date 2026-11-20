# Smolder Unlock

**Mac 重启后停在开机密码界面，用手机把它弄回来。**

一台常开的 Mac 有个软肋：重启或停电后会停在 FileVault 开机密码界面。这时 Mac 上什么都没跑起来，远程桌面、VPN、各种常驻程序都不在，只能等人走到机器前。

Smolder Unlock 是装在 Mac **之外**的那一部分：一个放在你自己登录后面的页面，显示 Mac 现在停在哪一步，需要时给一栏密码；另有一个看门的程序，Mac 在等你时发 Telegram（可选再发邮件）。

<p align="center"><a href="README.md">English</a> · <a href="AGENTS.md">给 AI Agent 的部署手册</a></p>

## 原理

macOS 26 起，开着「远程登录」时，在开机密码界面用密码 SSH 登录一次就会解开加密盘（`man apple_ssh_and_filevault`）。这套东西只是围着这一点搭的管道：

```text
你的手机 ── https://mac.example.com ── Cloudflare Access（邮箱验证码，只放行你）
                                           │ Cloudflare Tunnel（从你的服务器往外连）
                                你的服务器：unlockd.py（页面 + 看门）
                                           │ 用你输的密码 SSH 登录一次
                                Mac 的 SSH 端口，两种到法：
                                  · 家里一台常开的设备挂着反向通道
                                  · 直连（端口转发，或你已有的 VPN）
```

解开之后 Mac 停在登录窗口，用你平时的远程桌面登进去就行。

## 需要什么

| | |
|---|---|
| Mac | Apple 芯片，macOS 26 以上，FileVault 开着，「远程登录」开着。 |
| 合盖的笔记本 | 要接一台显示器或 HDMI 假显示器。不接的话，开机后几秒就在密码界面睡着，谁也连不上。Mac mini、Mac Studio 不需要。 |
| 一台服务器 | 任何常开的 Linux 主机，有 systemd、Python 3.9+、curl。它只往外连。 |
| 服务器到 Mac 的路 | Mac 锁着的时候不能自己往外连。要么**家里有一台常开的设备**（路由器、树莓派、NAS）向服务器挂一条反向 SSH 通道，要么家里有**公网地址并把一个端口转发**到 Mac 的 22。两样都没有就用不了。 |
| Cloudflare | 免费账号，域名托管在上面，Zero Trust 开通一次（免费档即可）。 |

## 你的密码会经过哪里

决定用之前先读这一段。

- 你在页面上输的是 Mac 的登录密码。它经 HTTPS 到 Cloudflare（Cloudflare 负责解密 HTTPS，看得到），经隧道到你的服务器，进 `unlockd.py` 的内存，再经 SSH 到 Mac。**Cloudflare 和你的服务器都看得到它。**不接受这一点就不要用。
- 在服务器上，它只存在于这个进程的内存和一个 `ssh` 子进程的环境变量里，登录那几秒。不写盘，不进日志。
- 页面要先过 Cloudflare Access 登录，只放行你列出的邮箱。服务器对每个请求还会再验一遍 Cloudflare 令牌的签名，没经过你那个 Access 应用的请求，哪怕来自服务器本机也会被拒。
- 服务器持有一把登 Mac 的钥匙。在 Mac 上这把钥匙被限制成只能执行一条命令：打印时钟和 Smolder 的心跳文件。开不了终端，转发不了端口，读不到别的。
- 密码连错三次，页面停 15 分钟。

## 安装

```bash
brew install penntiao/tap/smolder-unlock       # 或克隆本仓库，直接用 unlock/deploy.py
smolder-unlock init                             # 在当前目录生成 config.json
# 编辑 config.json
export CLOUDFLARE_API_TOKEN=…                  # 权限见下
export TELEGRAM_BOT_TOKEN=…                    # 配了 notify.telegram 才需要
smolder-unlock plan
smolder-unlock apply
```

`apply` 依次跑七步：`preflight`、`server`、`link`、`mac`、`cloudflare`、`start`、`verify`，每一步做完自己检查。每行以 `OK`、`FAIL`、`TODO`（只有你本人能做的事）或 `INFO` 开头。遇到第一个失败就停，修好后用 `smolder-unlock apply --step 名字` 重跑那一步。每一步都可以重复执行。

最后做唯一要紧的一次测试，人在家的时候做：重启 Mac，等报警，从页面解锁。

### config.json

| 键 | 含义 |
|---|---|
| `lang` | `"en"` 或 `"zh"`：报警用的语言。页面跟浏览器走。 |
| `mac.user` | macOS 的短用户名。 |
| `mac.lan_ip` | Mac 在家里内网的地址（反向通道模式用）。在路由器上给它固定下来。 |
| `server.ssh` | 从这台 Mac 怎么登服务器：`root@主机`，或能免密 `sudo` 的用户，或 `~/.ssh/config` 里的一个 `Host`。 |
| `server.install_dir`、`server.listen_port` | 默认 `/opt/smolder-unlock` 和 `3112`（只听回环）。 |
| `link.mode` | `"reverse"`：家里设备挂通道；默认端口 `39930` / `39931` 被占了就改 `mac_port_on_server` / `device_port_on_server`。设备要连的不是 `server.ssh` 里那个主机的 22 端口时（那里写的是别名、SSH 换了端口、要走本机代理口），填 `server_host` / `server_port`。`"direct"`：填服务器能连到 Mac SSH 的 `host` 和 `port`；可选 `check: {"host", "port"}`，一个只要回家的路通着就会应答的 SSH 端口，页面靠它分清「家里断线了」和「Mac 没有应答」。 |
| `cloudflare.zone`、`.hostname`、`.emails` | 你的域名、页面用的子域名、谁可以登录。 |
| `notify.telegram.chat_id` | 报警发给谁。机器人令牌从环境变量 `TELEGRAM_BOT_TOKEN` 读。 |
| `notify.email` | 可选的第二条通道：`{"host", "port", "user", "from", "to"}`，密码从 `SMTP_PASSWORD` 读。 |

### Cloudflare 令牌

在「我的个人资料 → API 令牌」建一个自定义令牌：

- 账户 · Cloudflare Tunnel · 编辑
- 账户 · Access：应用和策略 · 编辑
- 账户 · Access：组织、身份提供程序和组 · 编辑
- 区域 · 区域 · 读取，区域 · DNS · 编辑，限定到你的域名

这五项就够，安装和卸载都是用恰好这样一个令牌跑过的。

安装时先建 Access 应用，确认它恰好只有一条「只放行本人」的策略，然后才公开域名；卸载时顺序反过来。令牌只在你的 Mac 上用，不存到任何地方。

### 家里的设备（反向通道模式）

`apply` 会把服务器那一侧配好，并生成一个 `home-device/` 文件夹，里面有现成的 systemd 单元、OpenWrt 启动脚本和四行说明。装到那台常开的设备上，再接着跑 `smolder-unlock apply --step mac`。这台设备的钥匙只能在你的服务器上开两个回环端口。

### 分清「已登录」和「只是解开了」

不装 Smolder，页面只分得清「锁着」和「解开了」。装了 [Smolder](../README.zh-CN.md) 并让它把心跳写成文件，页面还能知道有没有人登进去，看门程序也会报「停在登录窗口」。在 Smolder → 设置 → 通知 → 自定义命令里打开「发送心跳」，命令填：

```bash
/bin/sh -c 'umask 077; f="$HOME/.local/state/smolder/heartbeat.json"; mkdir -p "${f%/*}"; cat > "$f.tmp" && mv "$f.tmp" "$f"'
```

## 你会看到什么

| 页面显示 | 含义 |
|---|---|
| 一切正常 | 已登录，Smolder 在报状态。 |
| 等待开机密码 | 停在开机密码界面，输密码。 |
| 已解锁 · 可以远控了 | 加密盘已解开，停在登录窗口。 |
| Mac 没有应答 | 关机、睡着，或掉网。 |
| 家里断线了 | 家里那条通道断了（反向通道模式）。 |

看门程序的节奏：不正常持续 10 分钟发一条（「等开机密码」3 分钟就发，因为它不会自己好），往前进一步发一条，满一小时发一条，恢复发一条；重启后很快自己回来的，发一条「重启过」。

## 测过的和没测过的

测过：MacBook Air M4（macOS 27.2，只有 Wi‑Fi，合盖插假显示器），Debian 13 arm64 服务器，反向通道由一台 OpenWrt 25.12 路由器维持：重启后在密码界面停 4 分钟、26 分钟，都从手机解开了；安装和卸载两种通道模式各完整跑过一遍，用的是受限令牌；OpenWrt 启动脚本在那台路由器上跑过，包括通道被杀掉后自己重连。

- 在开机密码界面，屏幕 5 分钟后熄，空闲 20 分钟后 Mac 自己睡着，但每来一个连接都会醒一下，所以页面会自动重试最多四次。
- macOS 解开之后不在那条 SSH 连接上回话，也不关它。所以服务器是从旁边看 Mac 的状态来确认解锁的，提交后几秒才显示「已解锁」。
- 上面那几次真重启用的是作者早先的自用版，逻辑相同；这份打包后的代码跑过安装、页面和各项检查，还没做过一次真解锁。
- 没测过：家里设备用的 systemd 单元、Intel Mac、只接网线的 Mac mini、在密码界面过夜、真实停电后的恢复。

## 卸载

```bash
smolder-unlock uninstall
```

会删掉 Cloudflare 上的路由、DNS 记录、Access 应用和隧道，服务器上的服务、文件和用户，Mac 上那一行钥匙；并告诉你家里设备上还剩什么要删。
