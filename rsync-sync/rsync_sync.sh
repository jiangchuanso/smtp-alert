#!/bin/bash
# rsync_sync.sh - 使用 rsync 同步两个文件夹，失败时通过 curl + SMTP 发送告警邮件
# 用法: ./rsync_sync.sh

# ==================== 配置区 ====================
# 源目录（末尾带 / 表示同步目录内容，不带 / 会把目录本身复制过去）
SRC_DIR="/data/source/"
# 目标目录，支持本地路径或远程: user@192.168.1.10:/data/backup/
DST_DIR="/data/backup/"

RSYNC_OPTS="-a --delete --stats"

# 失败重试次数与重试间隔(秒)
RETRY=2
RETRY_INTERVAL=10

# 首次失败告警后，若连续失败是否继续告警(true=每次都发, false=恢复成功前只发一次)
ALERT_EVERY_FAIL=true
STATE_FILE="/tmp/rsync_sync_alert.state"

# SMTP 配置（25=明文, 465=SSL, 587=STARTTLS；无需认证时 USER/PASS 留空）
SMTP_HOST="smtp.example.com"
SMTP_PORT="25"
SMTP_USER=""
SMTP_PASS=""
SMTP_FROM="alert@example.com"
SMTP_TO="admin@example.com"
# ================================================

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
    local subj="$1" body="$2"
    local subj_b64 mail_file
    subj_b64=$(printf '%s' "$subj" | base64 -w0)
    mail_file=$(mktemp)
    # 与已验证成功的 smart_curl_mail 插件保持一致：正文 8bit 原文、date -R、无尖括号
    {
        printf 'From: <%s>\n' "$SMTP_FROM"
        printf 'To: <%s>\n' "$SMTP_TO"
        printf 'Subject: =?UTF-8?B?%s?=\n' "$subj_b64"
        printf 'Date: %s\n' "$(LC_ALL=C date -R)"
        printf 'MIME-Version: 1.0\n'
        printf 'Content-Type: text/plain; charset=UTF-8\n'
        printf 'Content-Transfer-Encoding: 8bit\n'
        printf '\n'
        printf '%s\n' "$body"
    } > "$mail_file"
    # SMTP 要求 CRLF 行尾，curl 不做转换，统一转成 CRLF
    sed -i 's/$/\r/' "$mail_file"

    # 数组展开传参，密码/收件人含空格也不会被拆词
    local curl_args=(--url "$SMTP_URL")
    [ -n "$SSL_ARGS" ] && curl_args+=(--ssl-reqd)
    [ -n "$SMTP_USER" ] && curl_args+=(--user "${SMTP_USER}:${SMTP_PASS}")
    curl_args+=(--mail-from "$SMTP_FROM")
    local IFS=','
    read -ra RCPTS <<< "$SMTP_TO"
    for rcpt in "${RCPTS[@]}"; do
        curl_args+=(--mail-rcpt "${rcpt// /}")
    done

    curl -sS "${curl_args[@]}" \
        --upload-file "$mail_file" \
        --max-time 60 \
        --connect-timeout 15
    local rc=$?
    rm -f "$mail_file"
    return $rc
}

# flock 防止并发；旧版 mkdir 锁在进程被 kill -9 后会留下死锁目录，导致后续全部跳过
LOCK_FILE="/tmp/rsync_sync.lock"
exec 200>"$LOCK_FILE" 2>/dev/null || { echo "$(date '+%F %T') 无法创建锁文件: $LOCK_FILE" >&2; exit 1; }
if ! flock -n 200; then
    echo "$(date '+%F %T') 上一次同步仍在执行，跳过"
    exit 0
fi

[ -d "$SRC_DIR" ] || { echo "$(date '+%F %T') 源目录不存在: $SRC_DIR" >&2; exit 1; }

LOG_FILE=$(mktemp)
echo "$(date '+%F %T') 开始同步: ${SRC_DIR} -> ${DST_DIR}"

attempt=1
# RETRY 为"重试次数"，总尝试次数 = RETRY + 1（首次 + N 次重试）
MAX_ATTEMPTS=$((RETRY+1))
while :; do
    rsync $RSYNC_OPTS "$SRC_DIR" "$DST_DIR" > "$LOG_FILE" 2>&1
    rc=$?
    [ $rc -eq 0 ] && break
    [ $attempt -ge $MAX_ATTEMPTS ] && break
    attempt=$((attempt+1))
    echo "$(date '+%F %T') 第 $((attempt-1)) 次同步失败，${RETRY_INTERVAL}s 后重试($attempt/$MAX_ATTEMPTS)"
    sleep "$RETRY_INTERVAL"
done

if [ $rc -eq 0 ]; then
    if [ "$ALERT_EVERY_FAIL" = "false" ]; then
        rm -f "$STATE_FILE"
    fi
    summary=$(grep -E 'Number of (created|deleted|regular) files|total size' "$LOG_FILE" | head -4)
    echo "$(date '+%F %T') 同步成功 ${summary}"
    rm -f "$LOG_FILE"
    exit 0
fi

if [ "$ALERT_EVERY_FAIL" = "false" ] && [ -f "$STATE_FILE" ]; then
    echo "$(date '+%F %T') 同步失败，告警已发送过，跳过"
    rm -f "$LOG_FILE"
    exit 1
fi

HOSTNAME=$(hostname)
BODY="主机 ${HOSTNAME} 数据同步失败

源目录: ${SRC_DIR}
目标目录: ${DST_DIR}
重试次数: ${RETRY}
rsync 退出码: ${rc}
失败时间: $(date '+%F %T')

rsync 输出(最后 20 行):
----------------------------------------
$(tail -n 20 "$LOG_FILE")
----------------------------------------

请检查网络、目标主机及磁盘状态。
--
rsync_sync @ ${HOSTNAME}"

if send_mail "【告警】${HOSTNAME} 数据同步失败" "$BODY"; then
    echo "$rc" > "$STATE_FILE"
    echo "$(date '+%F %T') 同步失败，告警邮件已发送"
else
    echo "$(date '+%F %T') 同步失败且告警邮件发送失败!" >&2
fi

rm -f "$LOG_FILE"
exit 1
