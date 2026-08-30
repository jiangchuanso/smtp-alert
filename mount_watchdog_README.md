# SMB/NFS 共享挂载保活脚本使用说明

`mount_watchdog.sh` 用于保持 SMB/CIFS、NFS 共享目录的**常态挂载**：定时健康检查，掉线后自动重挂，重挂失败发 SMTP 告警邮件。

## 一、解决的核心问题

1. **掉线自动重连**：共享服务端重启或网络闪断后，挂载点不会自动恢复，本脚本定时检测并重挂
2. **防止数据写丢**：掉线期间挂载点退化为本地空目录，程序写入的文件在重挂后被远端内容遮蔽（看似丢失）。脚本在检测到掉线时立即**锁定挂载点目录**（`chmod 000` + 隐藏标记），阻断一切写入，重挂成功后自动解锁

## 二、功能特性

- 可写测试（`touch` 探针）而非仅 `stat`，避免缓存导致的误判健康
- 连续失败 N 次才触发重挂，防网络抖动误判（默认 2 次）
- 重挂先 `umount -f -l` 懒卸载，避免进程卡 D 状态导致重挂失败
- 告警去重：失联期间只发一次邮件，恢复后自动重新武装
- 支持 25（明文，默认）/ 465（SSL）/ 587（STARTTLS），支持免认证内网 SMTP
- 无并发问题：纯状态检测 + 重挂，幂等可重复执行

## 三、环境要求

- Linux，`bash` 4.0+，`root` 权限执行（mount/umount/chmod 需要）
- `curl`（需支持 SMTP）
- NFS 客户端：`yum install nfs-utils` 或 `apt install nfs-common`
- CIFS 客户端：`yum install cifs-utils` 或 `apt install cifs-utils`

## 四、安装部署

### 1. 创建挂载点目录（只创建一次，脚本不删除它）

```bash
mkdir -p /data/nfs
```

### 2. 上传脚本

```bash
mkdir -p /opt/scripts
cp mount_watchdog.sh /opt/scripts/
chmod +x /opt/scripts/mount_watchdog.sh
```

### 3. 修改配置

| 变量 | 说明 | 示例 |
|------|------|------|
| `MOUNT_POINT` | 本地挂载点目录 | `/data/nfs` |
| `SRC` | 远程源（NFS 或 SMB 格式） | `192.168.1.10:/share/nfs` 或 `//192.168.1.10/share` |
| `FSTYPE` | 文件系统类型 | `nfs` 或 `cifs` |
| `MOUNT_OPTS` | 挂载参数 | NFS: `defaults,_netdev,soft,timeo=50,retrans=5` |
| `LOCK_WHEN_DOWN` | 掉线时锁定本地目录 | `true`（推荐） |
| `FAIL_THRESHOLD` | 连续失败几次才重挂 | `2` |
| `ALERT_ON_FAIL` | 重挂失败是否发邮件 | `true` |
| `SMTP_*` | SMTP 配置，同 disk_monitor.sh | 见下 |

常用挂载参数参考：

**NFS：**

| 参数 | 说明 |
|------|------|
| `soft` | I/O 超时后返回错误而非无限挂起；有数据一致性要求改用 `hard,intr` |
| `timeo=50,retrans=5` | 超时 5 秒、重传 5 次 |
| `_netdev` | 声明网络设备，开机等网络就绪再挂 |

**SMB/CIFS：**

| 参数 | 说明 |
|------|------|
| `credentials=/etc/smb.cred` | 认证文件，格式两行：`username=xxx` / `password=xxx`，并 `chmod 600` |
| `uid=1000,gid=1000` | 挂载后文件归属的本地用户/组 |
| `iocharset=utf8` | 中文文件名不乱码 |
| `vers=3.0` | 指定 SMB 协议版本（老 NAS 可能需要 2.0/2.1） |

### 4. 手动测试

```bash
# 正常状态：输出无异常即通过
/opt/scripts/mount_watchdog.sh

# 验证掉线处理：临时改 SRC 为不可达地址后执行，应看到锁定目录、重挂失败
# 验证锁定效果：掉线期间 ls -ld /data/nfs 权限应为 ---，写入被拒绝
```

### 5. 首次挂载

脚本本身支持"从无到有"挂载（目录未挂载时健康检查失败→执行 mount）。也可先手动挂一次确认参数正确：

```bash
mount -t nfs -o defaults,_netdev,soft,timeo=50,retrans=5 192.168.1.10:/share/nfs /data/nfs
```

## 五、配置定时任务

若通过 RPM 包安装（`dnf install mount-watchdog-*.rpm`），`/etc/cron.d/mount_watchdog` 已自动装好并生效，无需手动配置。

手动部署时，将 `mount_watchdog.cron` 复制到 `/etc/cron.d/`（注意目标文件名不能带点）：

```bash
cp mount_watchdog.cron /etc/cron.d/mount_watchdog
chmod 644 /etc/cron.d/mount_watchdog
```

其中挂载保活任务为每 2 分钟执行一次。

与 rsync 同步配合时，保活（2 分钟）天然先于同步（30 分钟）执行，形成"自动重挂 → 恢复后正常同步 → 仍失败才收到 rsync 告警"的闭环。

## 六、告警效果

邮件主题：

```
【告警】web-server-01 共享挂载失联: /data/nfs
```

正文包含挂载点、远程源、文件系统类型、失败时间，并提示掉线期间目录已锁定。

## 七、常见问题

**Q: 掉线期间本地目录被锁了，程序写入会怎样？**
A: 写入会收到 Permission denied。这是刻意设计——比静默写进本地目录、重挂后数据"消失"要安全得多。程序应具备写入失败重试逻辑。

**Q: 锁定后重挂成功，权限会恢复吗？**
A: 会。重挂后目录权限由远端共享决定，本地 chmod 000 只作用于掉线期间的本地目录本身。脚本同时清理 `.mount_down` 标记。

**Q: NFS 进程卡死（D 状态）怎么办？**
A: 脚本已用 `umount -f -l` 懒卸载处理。若仍有进程卡住，等重挂成功后其 I/O 会自动恢复或报错返回。

**Q: 为什么用 touch 而不是 stat 检查？**
A: 掉线后内核可能返回挂载点缓存的 stat 结果造成"假活"；touch 创建临时文件是真实 I/O，结果可靠。

**Q: 如何强制重新告警？**
A: `rm -f /tmp/mount_watchdog_alert.state`。

**Q: 想同时保活多个挂载点？**
A: 复制一份脚本，修改 `MOUNT_POINT/SRC/FSTYPE/MOUNT_OPTS`，并把 `FAIL_COUNT_FILE`、`ALERT_STATE_FILE` 改成不同文件名（如加 `_smb` 后缀），分别加 crontab 即可。
