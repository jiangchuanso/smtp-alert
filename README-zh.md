# smtp-alert

一组纯 shell 编写的 Linux 监控 / 保活脚本。出问题时通过 `curl` 直连 SMTP 服务器
发送告警邮件（无需本地邮件服务），覆盖磁盘空间、共享挂载、数据同步三类场景。

## 组件一览

| 组件 | 目录 | 作用 |
|------|------|------|
| **disk-monitor** | `disk-monitor/` | 扫描所有挂载分区，使用率超过阈值时发送告警邮件。 |
| **mount-watchdog** | `mount-watchdog/` | 保持 SMB/CIFS、NFS 共享目录常态挂载；掉线自动重挂，掉线期间锁定本地目录防止数据写丢。 |
| **rsync-sync** | `rsync-sync/` | 用 rsync 同步目录，失败自动重试，重试仍失败则发 SMTP 告警。 |

每个目录下含脚本（`*.sh`）及其 cron 文件（`*.cron`）。

## 目录结构

```
smtp-alert/
├── disk-monitor/       # disk_monitor.sh + disk_monitor.cron
├── mount-watchdog/     # mount_watchdog.sh + mount_watchdog.cron
├── rsync-sync/         # rsync_sync.sh + rsync_sync.cron
├── packaging/          # RPM spec：disk-monitor / mount-watchdog / rsync-sync
├── .github/workflows/  # build-rpms.yml：构建 RPM 并发布到 Releases
├── README.md
└── README-zh.md
```

## 安装（RPM）

从 **GitHub Releases** 下载 RPM 后安装：

```bash
dnf install disk-monitor-*.rpm mount-watchdog-*.rpm rsync-sync-*.rpm
```

RPM 会把脚本装到 `/opt/scripts/`，并把 cron 文件放入 `/etc/cron.d/`，立即生效。

## 从源码构建

### 本地用 rpmbuild

```bash
sudo apt-get install -y rpm        # 或 yum install rpm
rpmbuild -bb --define "_sourcedir $PWD/disk-monitor" packaging/disk-monitor.spec
# mount-watchdog / rsync-sync 同理
```

### 通过 GitHub Actions

推送 `vX.Y.Z` 标签，或在 Actions 页手动运行工作流。工作流会自动构建三个 RPM
并发布到 GitHub Releases（手动运行且不填版本号时使用 `nightly-<时间戳>` 标签）。

## 环境要求

- Linux，`bash` 4.0+
- `curl` 支持 SMTP：`curl --version | grep smtp`
- 各工具额外依赖：磁盘监控需 `df`/`awk`/`stat`；挂载保活需 `nfs-utils`/`cifs-utils`；
  同步需 `rsync`

## 通用 SMTP 配置

每个脚本顶部都有“配置区”，通用发信变量如下：

| 变量 | 说明 | 示例 |
|------|------|------|
| `SMTP_HOST` | SMTP 服务器地址 | `smtp.163.com` |
| `SMTP_PORT` | 25 明文 / 465 SSL / 587 STARTTLS | `25` |
| `SMTP_USER` | 发件账号 | `alert@163.com` |
| `SMTP_PASS` | 密码或授权码（内网免认证可留空） | `XXXX` |
| `SMTP_FROM` | 发件人地址 | `alert@163.com` |
| `SMTP_TO` | 收件人，多个用英文逗号分隔 | `a@x.com,b@y.com` |

---

## 一、disk-monitor（磁盘空间监控）

监控各挂载分区使用率，超过阈值（默认 80%）时发告警邮件。

**特性**：自动排除 tmpfs / devtmpfs / squashfs 等虚拟挂载；告警去重（持续超阈值不重复发，恢复后自动重新武装）；多收件人；中文主题/正文 UTF-8 Base64 编码。

**手动测试**：

```bash
/opt/scripts/disk_monitor.sh          # 默认阈值 80
/opt/scripts/disk_monitor.sh 90       # 指定阈值 90（用 1 更容易触发）
```

**定时任务**：RPM 安装后 `/etc/cron.d/disk_monitor` 已生效；手动部署：

```bash
cp disk-monitor/disk_monitor.cron /etc/cron.d/disk_monitor
chmod 644 /etc/cron.d/disk_monitor
```

**常见问题**：中文乱码→确认 locale 支持 UTF-8；强制重新告警→`rm -f /tmp/disk_monitor_alert.state`；
`/tmp` 重启被清→把 `STATE_FILE` 改到 `/var/tmp/`；465/587 端口 SSL 报错→确认端口类型，内网中转多用 25。

---

## 二、mount-watchdog（共享挂载保活）

保持 SMB/CIFS、NFS 共享常态挂载：定时 `touch` 探针健康检查，掉线自动重挂，
重挂失败发邮件；掉线期间立即 `chmod 000` 锁定挂载点目录，阻断写入，重挂成功自动解锁。

**特性**：真实 I/O 探针避免缓存假活；连续失败 N 次才重挂（默认 2）；`umount -f -l` 懒卸载防 D 状态卡死；告警去重。

**手动测试**：

```bash
/opt/scripts/mount_watchdog.sh
# 验证掉线处理：临时改 SRC 为不可达地址，应看到锁定目录、重挂失败
```

**定时任务**：每 2 分钟执行一次。RPM 安装后 `/etc/cron.d/mount_watchdog` 已生效。

**与 rsync 配合**：保活（2 分钟）天然先于同步（30 分钟），形成“自动重挂 → 恢复后同步 → 仍失败才收 rsync 告警”闭环。

**常见问题**：掉线期间写入收到 Permission denied 是刻意设计（比静默写丢安全）；锁定后重挂成功权限由远端决定；多挂载点→复制脚本并改 `MOUNT_POINT/SRC/FSTYPE/MOUNT_OPTS` 及状态文件名。

---

## 三、rsync-sync（数据同步告警）

用 rsync 把源目录同步到目标（本地或远程），同步失败（含重试后仍失败）发告警邮件，
邮件含 rsync 退出码与最后 20 行输出。

**特性**：增量同步；失败自动重试（默认 2 次，间隔 10 秒）；锁文件防并发；可选告警去重；支持远程 SSH 免密。

**手动测试**：

```bash
/opt/scripts/rsync_sync.sh
```

**定时任务**：每 30 分钟执行一次。RPM 安装后 `/etc/cron.d/rsync_sync` 已生效。

**rsync 参数**：默认 `-a --delete --stats`。`--delete` 保证两端一致（首次使用请确认无反向误删风险）；
不想删改 `-a --stats`；跨机房慢链路加 `-z`、限速 `--bwlimit=50000`、试运行 `--dry-run`。

**远程 SSH 免密**：

```bash
ssh-keygen -t ed25519
ssh-copy-id user@192.168.1.10
```

**常见退出码**：23 部分文件失败（权限/属性）；24 源文件传输中消失；255 SSH 连接失败；30/11 超时。

**常见问题**：`SRC_DIR` 末尾 `/` 决定同步“内容”还是“目录本身”；强制重新告警→`rm -f /tmp/rsync_sync_alert.state`；
“上一次同步仍在执行”→确认无 rsync 进程后 `rm -rf /tmp/rsync_sync.lock`。

---

## 许可证

MIT
