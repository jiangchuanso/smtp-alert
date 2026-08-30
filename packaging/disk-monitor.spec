Name:           disk-monitor
Version:        %{?_version}%{!?_version:1.0.0}
Release:        1
Summary:        Disk usage monitor with SMTP alerting
BuildArch:      noarch
License:        MIT
Source0:        disk_monitor.sh
Source1:        disk_monitor.cron
Requires:       bash, curl, coreutils, gawk, grep
AutoReqProv:    no

%description
Scans all mounted partitions and sends SMTP alert email via curl
when usage exceeds the threshold. Pure shell implementation with
alert deduplication and auto-rearm on recovery.

%prep

%build

%install
install -Dm755 %{SOURCE0} %{buildroot}/opt/scripts/disk_monitor.sh
install -Dm644 %{SOURCE1} %{buildroot}/etc/cron.d/disk_monitor

%files
%dir /opt/scripts
/opt/scripts/disk_monitor.sh
%config(noreplace) /etc/cron.d/disk_monitor

%changelog
* Mon Jan 01 2026 maintainer - 1.0.0
- Initial release
