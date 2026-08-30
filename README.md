<p align="center">
  <b>English</b> · <a href="./README-zh.md">中文</a>
</p>

# smtp-alert

A collection of pure-shell Linux monitoring / keepalive scripts that send SMTP alert
emails via `curl` (no local mail server required) when something goes wrong.

## Components

| Component | Folder | Purpose |
|-----------|--------|---------|
| **disk-monitor** | `disk-monitor/` | Scans all mounted partitions and alerts when disk usage exceeds a threshold. |
| **mount-watchdog** | `mount-watchdog/` | Keeps SMB/CIFS and NFS shares permanently mounted; auto-remounts on failure and locks the mount point while down to prevent writes from silently going to the local directory. |
| **rsync-sync** | `rsync-sync/` | rsync folder sync with automatic retries and an SMTP alert on failure. |

Each folder contains the script (`*.sh`) and its cron file (`*.cron`).

## Directory layout

```
smtp-alert/
├── disk-monitor/       # disk_monitor.sh + disk_monitor.cron
├── mount-watchdog/     # mount_watchdog.sh + mount_watchdog.cron
├── rsync-sync/         # rsync_sync.sh + rsync_sync.cron
├── packaging/          # RPM spec files: disk-monitor / mount-watchdog / rsync-sync
├── .github/workflows/  # build-rpms.yml: builds RPMs and publishes them to Releases
├── README.md
└── README-zh.md
```

## Installation (RPM)

Download the RPMs from **GitHub Releases** and install:

```bash
dnf install disk-monitor-*.rpm mount-watchdog-*.rpm rsync-sync-*.rpm
```

The RPMs install the scripts to `/opt/scripts/` and drop cron files into
`/etc/cron.d/`, which take effect immediately.

## Building from source

### Locally with rpmbuild

```bash
sudo apt-get install -y rpm        # or: yum install rpm
rpmbuild -bb --define "_sourcedir $PWD/disk-monitor" packaging/disk-monitor.spec
# repeat for mount-watchdog / rsync-sync
```

### Via GitHub Actions

Push a tag `vX.Y.Z`, or run the workflow manually from the Actions tab.
The workflow builds all three RPMs and publishes them to GitHub Releases
automatically (manual runs without a version use a `nightly-<timestamp>` tag).

## Requirements

- Linux, `bash` 4.0+
- `curl` with SMTP support: `curl --version | grep smtp`
- Per tool: `df`/`awk`/`stat` (disk-monitor), `nfs-utils`/`cifs-utils`
  (mount-watchdog), `rsync` (rsync-sync)

## Configuration

Every script has a configuration block at the top. Common SMTP settings:

| Variable | Description | Example |
|----------|-------------|---------|
| `SMTP_HOST` | SMTP server address | `smtp.163.com` |
| `SMTP_PORT` | 25 plain / 465 SSL / 587 STARTTLS | `25` |
| `SMTP_USER` | Account | `alert@163.com` |
| `SMTP_PASS` | Password / app token | `XXXX` |
| `SMTP_FROM` | Sender | `alert@163.com` |
| `SMTP_TO` | Recipients (comma separated) | `a@x.com,b@y.com` |

For detailed per-tool usage, cron schedules, and FAQ, see `README-zh.md`.

## License

MIT
