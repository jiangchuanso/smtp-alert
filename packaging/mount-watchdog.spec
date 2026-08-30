Name:           mount-watchdog
Version:        %{?_version}%{!?_version:1.0.0}
Release:        1
Summary:        SMB/NFS mount keepalive with auto remount and SMTP alerting
BuildArch:      noarch
License:        MIT
Source0:        mount_watchdog.sh
Source1:        mount_watchdog.cron
Requires:       bash, curl, coreutils, util-linux
AutoReqProv:    no

%description
Keeps SMB/CIFS and NFS shares permanently mounted: periodic health
check with real I/O probe, locks the mount point directory when the
share goes down to prevent writes into the local directory, auto
remount on failure, SMTP alert when remount fails.
NFS requires nfs-utils, CIFS requires cifs-utils (install as needed).

%prep

%build

%install
install -Dm755 %{SOURCE0} %{buildroot}/opt/scripts/mount_watchdog.sh
install -Dm644 %{SOURCE1} %{buildroot}/etc/cron.d/mount_watchdog

%files
%dir /opt/scripts
/opt/scripts/mount_watchdog.sh
%config(noreplace) /etc/cron.d/mount_watchdog

%changelog
* Mon Jan 01 2026 maintainer - 1.0.0
- Initial release
