#!/bin/bash
# disk_monitor.sh - 监控分区空间使用率，超阈值时通过 curl + SMTP 发送告警邮件
# 用法: ./disk_monitor.sh [阈值]

# ==================== 配置区 ====================
THRESHOLD="${1:-80}"

SMTP_HOST="smtp.example.com"
SMTP_PORT="25"
SMTP_USER=""
SMTP_PASS=""
SMTP_FROM="alert@example.com"
SMTP_TO="admin@example.com"

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

EXCLUDE_REGEX='^(tmpfs|devtmpfs|overlay|squashfs|iso9660|udev)$'
STATE_FILE="/tmp/disk_monitor_alert.state"
# ================================================

HOSTNAME=$(hostname)

ALERTS=$(df -P -x tmpfs -x devtmpfs 2>/dev/null | awk -v th="$THRESHOLD" '
    NR>1 && $1 !~ /^\/dev\/loop/ {
        usage=int($5); mount=$6
        if (usage >= th) print $1, mount, usage
    }')

if [ -n "$ALERTS" ]; then
    FILTERED=""
    while IFS=' ' read -r fs mount usage; do
        fstype=$(stat -f -c %T "$mount" 2>/dev/null)
        echo "$fstype" | grep -Eq "$EXCLUDE_REGEX" && continue
        FILTERED+="${fs} ${mount} ${usage}"$'\n'
    done <<< "$ALERTS"
    ALERTS="$FILTERED"
fi

if [ -z "$ALERTS" ]; then
    [ -f "$STATE_FILE" ] && rm -f "$STATE_FILE" && \
        echo "$(date '+%F %T') 所有分区已恢复至阈值以下，清除告警状态"
    exit 0
fi

ALERT_HASH=$(echo "$ALERTS" | sort | md5sum | cut -d' ' -f1)
if [ -f "$STATE_FILE" ] && [ "$(cat "$STATE_FILE")" = "$ALERT_HASH" ]; then
    echo "$(date '+%F %T') 告警内容未变化，跳过发送"
    exit 0
fi

BODY="主机 ${HOSTNAME} 磁盘空间告警

以下分区使用率已超过 ${THRESHOLD}%：

文件系统        挂载点          使用率
----------------------------------------
$(echo "$ALERTS" | awk '{printf "%-16s %-16s %s%%\n", $1, $2, $3}')

请及时清理磁盘空间。
--
disk_monitor @ ${HOSTNAME}
$(date '+%F %T')"

# 与已验证成功的 smart_curl_mail 插件保持一致：
# 正文用 8bit 原文，Date 头用 date -R，curl 的 FROM/RCPT 不带尖括号
SUBJ_B64=$(printf '%s' "【告警】${HOSTNAME} 磁盘空间不足" | base64 -w0)

MAIL_FILE=$(mktemp)
{
    printf 'From: <%s>\n' "$SMTP_FROM"
    printf 'To: <%s>\n' "$SMTP_TO"
    printf 'Subject: =?UTF-8?B?%s?=\n' "$SUBJ_B64"
    printf 'Date: %s\n' "$(LC_ALL=C date -R)"
    printf 'MIME-Version: 1.0\n'
    printf 'Content-Type: text/plain; charset=UTF-8\n'
    printf 'Content-Transfer-Encoding: 8bit\n'
    printf '\n'
    printf '%s\n' "$BODY"
} > "$MAIL_FILE"
# SMTP 要求 CRLF 行尾，curl 不做转换，统一转成 CRLF
sed -i 's/$/\r/' "$MAIL_FILE"

CURL_ARGS=(--url "$SMTP_URL")
[ -n "$SSL_ARGS" ] && CURL_ARGS+=(--ssl-reqd)
# 免认证模式下不加 --user，避免 curl 空凭证触发 AUTH 协商导致部分服务器断连
[ -n "$SMTP_USER" ] && CURL_ARGS+=(--user "${SMTP_USER}:${SMTP_PASS}")
CURL_ARGS+=(--mail-from "$SMTP_FROM")
IFS=',' read -ra RCPTS <<< "$SMTP_TO"
for rcpt in "${RCPTS[@]}"; do
    CURL_ARGS+=(--mail-rcpt "${rcpt// /}")
done

# 数组展开传参，密码/收件人含空格也不会被拆词
CURL_ERR=$(curl -sS "${CURL_ARGS[@]}" \
    --upload-file "$MAIL_FILE" \
    --max-time 60 \
    --connect-timeout 15 2>&1)
if [ $? -eq 0 ]; then
    echo "$ALERT_HASH" > "$STATE_FILE"
    echo "$(date '+%F %T') 告警邮件已发送: $ALERTS"
else
    echo "$(date '+%F %T') 邮件发送失败: ${CURL_ERR:-未知错误}" >&2
fi

rm -f "$MAIL_FILE"
