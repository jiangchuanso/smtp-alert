Name:           rsync-sync
Version:        %{?_version}%{!?_version:1.0.0}
Release:        1
Summary:        rsync folder sync with SMTP alerting on failure
BuildArch:      noarch
License:        MIT
Source0:        rsync_sync.sh
Source1:        rsync_sync.cron
Requires:       bash, curl, rsync, coreutils, util-linux
AutoReqProv:    no

%description
Syncs a source folder to a local or remote target via rsync with
automatic retries on failure, SMTP alert containing the rsync exit
code and output tail, concurrency lock and alert deduplication.
Remote sync over SSH requires openssh-clients with key auth.

%prep

%build

%install
install -Dm755 %{SOURCE0} %{buildroot}/opt/scripts/rsync_sync.sh
install -Dm644 %{SOURCE1} %{buildroot}/etc/cron.d/rsync_sync

%files
%dir /opt/scripts
/opt/scripts/rsync_sync.sh
%config(noreplace) /etc/cron.d/rsync_sync

%changelog
* Mon Jan 01 2026 maintainer - 1.0.0
- Initial release
