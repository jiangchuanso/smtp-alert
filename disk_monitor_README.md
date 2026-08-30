# 磁盘空间监控告警脚本使用说明

`disk_monitor.sh` 用于监控服务器上各挂载分区的磁盘空间使用率，当使用率超过设定阈值时，通过 `curl` 直连 SMTP 服务器发送告警邮件。

## 一、功能特性

- 扫描所有挂载分区，使用率超过阈值（默认 80%）时触发告警
- 自动排除 tmpfs、devtmpfs、snap loop、squashfs 等无意义的挂载点
- 告警去重：同一批分区持续超阈值时不重复发邮件；恢复到阈值以下后状态自动清除，再次超阈值可重新告警
- 支持多收件人（逗号分隔）
- 支持三种 SMTP 端口：25（明文，默认）、465（SSL）、587（STARTTLS）
- 中文主题和正文使用 UTF-8 Base64 编码，兼容各类邮件客户端

## 二、环境要求

- Linux 服务器（CentOS / Ubuntu / Debian 等）
- `curl` 7.20+（需支持 SMTP，`curl --version` 中有 `smtp` 字样即可）
- `bash` 4.0+
- 常用工具：`df`、`awk`、`stat`、`md5sum`、`base64`（系统一般自带）

检查 curl 是否支持 SMTP：

```bash
curl --version | grep smtp
```

## 三、安装部署

### 1. 上传脚本

将 `disk_monitor.sh` 上传到服务器，建议放在统一脚本目录：

```bash
mkdir -p /opt/scripts
cp disk_monitor.sh /opt/scripts/
chmod +x /opt/scripts/disk_monitor.sh
```

### 2. 修改配置

编辑脚本顶部"配置区"，按实际环境修改以下变量：

| 变量 | 说明 | 示例 |
|------|------|------|
| `SMTP_HOST` | SMTP 服务器地址 | `smtp.163.com` |
| `SMTP_PORT` | 端口：25 明文 / 465 SSL / 587 STARTTLS | `25` |
| `SMTP_USER` | 发件邮箱账号 | `alert@163.com` |
| `SMTP_PASS` | 邮箱密码或授权码（推荐授权码） | `XXXXXXXX` |
| `SMTP_FROM` | 发件人地址（一般与 SMTP_USER 相同） | `alert@163.com` |
| `SMTP_TO` | 收件人，多个用英文逗号分隔 | `a@x.com,b@y.com` |

其他可选配置：

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `EXCLUDE_REGEX` | 排除的文件系统类型（正则） | tmpfs 等虚拟文件系统 |
| `STATE_FILE` | 去重状态文件路径 | `/tmp/disk_monitor_alert.state` |

常见邮箱的 SMTP 配置参考：

| 邮箱 | SMTP_HOST | 端口 | 密码说明 |
|------|-----------|------|----------|
| 163 企业邮 | smtp.163.com / smtp.qiye.163.com | 465 或 994 | 客户端授权码 |
| QQ 企业邮 | smtp.exmail.qq.com | 465 | 客户端专用密码 |
| 阿里企业邮 | smtp.qiye.aliyun.com | 465 | 登录密码 |
| 自建 Postfix | 内网服务器 IP | 25 | 可留空 |

### 3. 手动测试

```bash
# 使用默认阈值 80 测试
/opt/scripts/disk_monitor.sh

# 指定阈值 90 测试（用低阈值更容易触发，如 1）
/opt/scripts/disk_monitor.sh 1
```

正常输出 `告警邮件已发送` 即表示成功，检查收件箱（注意垃圾邮件箱）。

### 4. 调试技巧

若发送失败，可临时在脚本的 curl 命令中把 `-sS` 改为 `-v` 查看完整的 SMTP 交互过程，根据服务器返回码定位问题：

- `535` 认证失败 → 检查账号/授权码
- `554` 被拒信 → 发件地址可能未获许可，或被对方反垃圾拦截
- 连接超时 → 检查网络、防火墙是否放行对应端口

## 四、配置定时任务

若通过 RPM 包安装（`dnf install disk-monitor-*.rpm`），`/etc/cron.d/disk_monitor` 已自动装好并生效，无需手动配置。

手动部署时，将 `disk_monitor.cron` 复制到 `/etc/cron.d/`（注意目标文件名不能带点）：

```bash
cp disk_monitor.cron /etc/cron.d/disk_monitor
chmod 644 /etc/cron.d/disk_monitor
```

如需自定义阈值，编辑 cron 文件中的执行行：

```cron
*/10 * * * * root /opt/scripts/disk_monitor.sh 90 >> /var/log/disk_monitor.log 2>&1
```

## 五、告警效果

收到邮件主题为：

```
【告警】web-server-01 磁盘空间不足
```

正文示例：

```
主机 web-server-01 磁盘空间告警

以下分区使用率已超过 80%：

文件系统        挂载点          使用率
----------------------------------------
/dev/sda1       /               92%
/dev/sdb1       /data           85%

请及时清理磁盘空间。
```

## 六、常见问题

**Q: 邮件中的中文显示乱码？**
A: 脚本已使用 UTF-8 Base64 编码，如仍乱码请确认系统 locale 支持 UTF-8（`locale` 命令查看）。

**Q: 如何强制重新发送告警？**
A: 删除状态文件即可：`rm -f /tmp/disk_monitor_alert.state`。

**Q: 服务器没有外网，能发邮件吗？**
A: 可以，只要能访问内网 SMTP 服务器（如自建 Postfix / Exchange），将 `SMTP_HOST` 指向内网地址即可。

**Q: 使用 465/587 端口时报 SSL 错误？**
A: 确认端口类型正确：465 是 SSL 直连，587 是 STARTTLS。公司内网中转服务器一般用 25 端口明文。

**Q: /tmp 目录重启后被清理导致重复告警？**
A: 可将 `STATE_FILE` 改到持久化目录，如 `/var/tmp/disk_monitor_alert.state`。
