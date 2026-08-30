# rsync 数据同步告警脚本使用说明

`rsync_sync.sh` 使用 `rsync` 将源目录同步到目标目录（本地或远程），同步失败（含重试后仍失败）时通过 `curl` 直连 SMTP 服务器发送告警邮件。

## 一、功能特性

- rsync 增量同步，仅传输差异部分，效率高
- 失败自动重试（默认 2 次，间隔 10 秒可配置）
- 重试仍失败后发送告警邮件，包含 rsync 退出码和最后 20 行输出，便于定位原因
- 锁文件防并发：上次同步未结束时自动跳过本次执行
- 可选告警去重：连续失败时只发一次邮件，恢复成功后重新武装
- 支持 25（明文，默认）/ 465（SSL）/ 587（STARTTLS）端口，支持免认证内网 SMTP

## 二、环境要求

- Linux 服务器，`bash` 4.0+
- `rsync`（`rsync --version` 确认，本地/远程两端都需安装）
- `curl`（需支持 SMTP）
- 同步到远程主机时需配置 SSH 免密登录（ssh-keygen + ssh-copy-id）

## 三、安装部署

### 1. 上传脚本

```bash
mkdir -p /opt/scripts
cp rsync_sync.sh /opt/scripts/
chmod +x /opt/scripts/rsync_sync.sh
```

### 2. 修改配置

编辑脚本顶部"配置区"：

| 变量 | 说明 | 示例 |
|------|------|------|
| `SRC_DIR` | 源目录。末尾带 `/` 同步目录**内容**；不带 `/` 会把目录本身复制到目标下 | `/data/source/` |
| `DST_DIR` | 目标目录，本地路径或远程路径 | `/data/backup/` 或 `user@192.168.1.10:/data/backup/` |
| `RSYNC_OPTS` | rsync 参数 | `-a --delete --stats` |
| `RETRY` | 失败重试次数 | `2` |
| `RETRY_INTERVAL` | 重试间隔（秒） | `10` |
| `ALERT_EVERY_FAIL` | 连续失败时是否每次都发邮件 | `true` |
| `SMTP_*` | SMTP 发信配置，与 disk_monitor.sh 相同 | 见下 |

SMTP 配置说明（同磁盘监控脚本）：

| 变量 | 说明 |
|------|------|
| `SMTP_HOST` | SMTP 服务器地址，如 `smtp.163.com` 或内网中转服务器 IP |
| `SMTP_PORT` | 25 明文（默认）/ 465 SSL / 587 STARTTLS |
| `SMTP_USER` / `SMTP_PASS` | 认证账号与密码/授权码；内网免认证服务器留空即可 |
| `SMTP_FROM` | 发件人地址 |
| `SMTP_TO` | 收件人，多个用英文逗号分隔 |

### 3. rsync 参数说明

默认 `RSYNC_OPTS="-a --delete --stats"`：

| 参数 | 含义 |
|------|------|
| `-a` | 归档模式：递归 + 保留权限/属主/时间戳/软链接等 |
| `--delete` | 删除目标端源目录中已不存在的文件，保证完全一致（**首次使用请确认无反向误删风险**） |
| `--stats` | 输出统计信息，便于日志查看 |

常用扩展参数：

```bash
--exclude='*.log'        # 排除某些文件
--exclude='.git/'
-z                       # 传输时压缩，适合跨机房慢速链路
--bwlimit=50000          # 限速 50MB/s，避免影响业务
--partial                # 中断后保留部分传输文件，下次续传
```

### 4. 远程同步的 SSH 免密配置

目标为远程主机时（`DST_DIR="user@host:/path/"`），先配置免密：

```bash
ssh-keygen -t ed25519          # 一路回车
ssh-copy-id user@192.168.1.10  # 分发公钥
ssh user@192.168.1.10 'rsync --version'   # 验证
```

> 远程模式要求**两端**都装有 rsync。

### 5. 手动测试

```bash
/opt/scripts/rsync_sync.sh
```

观察输出：`同步成功` 即可；人为制造失败（如把 `DST_DIR` 改成不可达地址）验证告警邮件能收到。

### 6. 调试技巧

- 手动执行同样参数的 rsync 观察详细输出：

```bash
rsync -av --delete /data/source/ /data/backup/
```

- 远程同步失败先确认：`ssh user@host echo ok` 是否正常、防火墙是否放行 22 端口
- 邮件发送失败排查方法同 disk_monitor.sh（把 curl 的 `-sS` 改 `-v` 查看 SMTP 交互）

## 四、配置定时任务

若通过 RPM 包安装（`dnf install rsync-sync-*.rpm`），`/etc/cron.d/rsync_sync` 已自动装好并生效，无需手动配置。

手动部署时，将 `rsync_sync.cron` 复制到 `/etc/cron.d/`（注意目标文件名不能带点）：

```bash
cp rsync_sync.cron /etc/cron.d/rsync_sync
chmod 644 /etc/cron.d/rsync_sync
```

其中 rsync 同步任务为每 30 分钟执行一次。

## 五、告警效果

邮件主题：

```
【告警】web-server-01 数据同步失败
```

正文包含：源/目标目录、重试次数、rsync 退出码、失败时间、rsync 输出最后 20 行。

常见退出码含义：

| 退出码 | 含义 |
|--------|------|
| 23 | 部分文件传输失败（权限/属性问题） |
| 24 | 源文件在传输过程中消失 |
| 255 | SSH 连接失败（远程模式） |
| 30/11 | 超时（网络问题） |

## 六、常见问题

**Q: 源目录末尾的 `/` 很重要吗？**
A: 是。`/data/source/` 同步的是 source 目录里的内容到目标；`/data/source` 会把 source 目录本身放到目标下（结果是 `/data/backup/source/...`）。

**Q: 不想用 `--delete` 怕误删？**
A: 把 `RSYNC_OPTS` 改为 `-a --stats` 即为只增不删的备份模式；也可先加 `--dry-run` 试运行查看会删除哪些文件。

**Q: 连续失败只收到一封告警，想每次失败都收到？**
A: 保持 `ALERT_EVERY_FAIL=true`（默认）；反之设为 `false` 可避免邮件轰炸。

**Q: 如何强制重新告警？**
A: 删除状态文件：`rm -f /tmp/rsync_sync_alert.state`。

**Q: 提示"上一次同步仍在执行"？**
A: 锁文件未释放（如进程被强杀），确认无 rsync 进程后删除锁目录：`rm -rf /tmp/rsync_sync.lock`。
