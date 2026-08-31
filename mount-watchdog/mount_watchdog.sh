#!/bin/bash
# mount_watchdog.sh - SMB/NFS 共享常态挂载保活，掉线自动重挂并锁定本地目录防止误写入
# 用法: ./mount_watchdog.sh  建议配合 crontab 每 2 分钟执行一次

# ==================== 配置区 ====================
MOUNT_POINT="/data/nfs"
SRC="192.168.1.10:/share/nfs"
FSTYPE="nfs"
MOUNT_OPTS="defaults,_netdev,soft,timeo=50,retrans=5"

LOCK_WHEN_DOWN=true
CHECK_TIMEOUT=5
FAIL_THRESHOLD=2

ALERT_ON_FAIL=true
SMTP_HOST="smtp.example.com"
SMTP_PORT="25"
SMTP_USER="alert@example.com"
SMTP_PASS="your-password"
SMTP_FROM="alert@example.com"
SMTP_TO="admin@example.com"
# ================================================

FAIL_COUNT_FILE="/tmp/mount_watchdog_fail.count"
ALERT_STATE_FILE="/tmp/mount_watchdog_alert.state"
MODE_FILE="/tmp/mount_watchdog_mode"

if [ "$SMTP_PORT" = "465" ]; then
    SMTP_URL="smtps://${SMTP_HOST}:${SMTP_PORT}"
    SSL_ARGS="--ssl-reqd"
elif [ "$SMTP_PORT" = "587" ]; then
    SMTP_URL="smtp://${SMTP_HOST}:${SMTP_PORT}"
    SSL_ARGS="--ssl-reqd"
else
    SMTP_URL="smtp://${SMTP_HOST}:${SMTP_PORT}"
    SSL_ARGS=""
fi

send_mail() {
    local subj_b64 body_b64 mail_file rc
    subj_b64=$(echo "$1" | base64 -w0)
    body_b64=$(echo "$2" | base64 -w0)
    mail_file=$(mktemp)
    {
        echo "From: <${SMTP_FROM}>"
        echo "To: <${SMTP_TO}>"
        echo "Subject: =?UTF-8?B?${subj_b64}?="
        # RFC 5322 Date 头必须是英文星期/月份，强制 C locale
        echo "Date: $(LC_ALL=C date '+%a, %d %b %Y %H:%M:%S %z')"
        echo "MIME-Version: 1.0"
        echo "Content-Type: text/plain; charset=UTF-8"
        echo "Content-Transfer-Encoding: base64"
        echo ""
        echo "$body_b64" | fold -w 76
    } > "$mail_file"
    # 数组展开传参，密码/收件人含空格也不会被拆词
    local curl_args=(--url "$SMTP_URL")
    [ -n "$SSL_ARGS" ] && curl_args+=(--ssl-reqd)
    curl_args+=(--user "${SMTP_USER}:${SMTP_PASS}" --mail-from "<${SMTP_FROM}>")
    local IFS=','
    read -ra RCPTS <<< "$SMTP_TO"
    for rcpt in "${RCPTS[@]}"; do
        curl_args+=(--mail-rcpt "${rcpt// /}")
    done
    curl -sS "${curl_args[@]}" \
        --upload-file "$mail_file" \
        --max-time 60 --connect-timeout 15
    rc=$?
    rm -f "$mail_file"
    return $rc
}

lock_point() {
    [ "$LOCK_WHEN_DOWN" = "true" ] || return 0
    # 先保存原始权限，恢复时还原；否则锁定后权限被永久改写
    stat -c %a "$MOUNT_POINT" 2>/dev/null > "$MODE_FILE" || echo 755 > "$MODE_FILE"
    # 对已失联(可能 hung 死)的挂载点做 IO 必须加 timeout，否则脚本会永久卡住
    timeout "$CHECK_TIMEOUT" touch "$MOUNT_POINT/.mount_down" 2>/dev/null
    timeout "$CHECK_TIMEOUT" chmod 000 "$MOUNT_POINT" 2>/dev/null
}

unlock_point() {
    [ "$LOCK_WHEN_DOWN" = "true" ] || return 0
    local mode
    mode=$(cat "$MODE_FILE" 2>/dev/null)
    [ -n "$mode" ] || mode=755
    timeout "$CHECK_TIMEOUT" chmod "$mode" "$MOUNT_POINT" 2>/dev/null
    rm -f "$MODE_FILE"
    timeout "$CHECK_TIMEOUT" rm -f "$MOUNT_POINT/.mount_down" 2>/dev/null
}

health_check() {
    # 必须先确认挂载点确实是远程挂载，否则共享未挂载时 touch 本地目录
    # 也会成功，导致永远检测不到掉线、不会重挂
    mountpoint -q "$MOUNT_POINT" || return 1
    timeout "$CHECK_TIMEOUT" touch "$MOUNT_POINT/.health_check" 2>/dev/null
    local rc=$?
    timeout "$CHECK_TIMEOUT" rm -f "$MOUNT_POINT/.health_check" 2>/dev/null
    return $rc
}

[ -d "$MOUNT_POINT" ] || { echo "$(date '+%F %T') 挂载点不存在: $MOUNT_POINT" >&2; exit 1; }

if health_check; then
    echo 0 > "$FAIL_COUNT_FILE"
    unlock_point
    if [ -f "$ALERT_STATE_FILE" ]; then
        rm -f "$ALERT_STATE_FILE"
        echo "$(date '+%F %T') 挂载点已恢复: $MOUNT_POINT"
    fi
    exit 0
fi

FAIL_COUNT=$(cat "$FAIL_COUNT_FILE" 2>/dev/null)
case "$FAIL_COUNT" in ''|*[!0-9]*) FAIL_COUNT=0 ;; esac
FAIL_COUNT=$((FAIL_COUNT+1))
echo "$FAIL_COUNT" > "$FAIL_COUNT_FILE"

if [ "$FAIL_COUNT" -lt "$FAIL_THRESHOLD" ]; then
    echo "$(date '+%F %T') 健康检查失败($FAIL_COUNT/$FAIL_THRESHOLD)，暂不处理"
    exit 0
fi

# 先卸载再锁定：保证 .mount_down 标记和 chmod 写入的是本地目录而非失联的远程挂载
umount -f -l "$MOUNT_POINT" 2>/dev/null
lock_point
echo "$(date '+%F %T') 挂载点失联: $MOUNT_POINT，尝试重挂"
sleep 2
mount -t "$FSTYPE" -o "$MOUNT_OPTS" "$SRC" "$MOUNT_POINT"

if health_check; then
    unlock_point
    echo 0 > "$FAIL_COUNT_FILE"
    if [ -f "$ALERT_STATE_FILE" ]; then
        rm -f "$ALERT_STATE_FILE"
        echo "$(date '+%F %T') 重挂成功，恢复访问: $MOUNT_POINT"
    else
        echo "$(date '+%F %T') 重挂成功: $MOUNT_POINT"
    fi
    exit 0
fi

echo "$(date '+%F %T') 重挂失败" >&2
[ "$ALERT_ON_FAIL" = "true" ] || exit 1
[ -f "$ALERT_STATE_FILE" ] && exit 1

HOSTNAME=$(hostname)
BODY="主机 ${HOSTNAME} 共享挂载失联且重挂失败

挂载点: ${MOUNT_POINT}
远程源: ${SRC}
文件系统: ${FSTYPE}
失败时间: $(date '+%F %T')

掉线期间挂载点目录已被锁定(不可写入)，防止数据写入本地目录。
请检查网络连通性及共享服务器状态。
--
mount_watchdog @ ${HOSTNAME}"

if send_mail "【告警】${HOSTNAME} 共享挂载失联: ${MOUNT_POINT}" "$BODY"; then
    echo 1 > "$ALERT_STATE_FILE"
    echo "$(date '+%F %T') 告警邮件已发送"
else
    echo "$(date '+%F %T') 告警邮件发送失败!" >&2
fi
exit 1
