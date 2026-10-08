{ config, pkgs, ... }:
{
  sops.secrets.nero-bot-token = { };
  sops.templates."netdata-telegram" = {
    owner = "netdata";
    mode = "0400";
    content = ''
      SEND_EMAIL="NO"
      SEND_TELEGRAM="YES"
      TELEGRAM_BOT_TOKEN="${config.sops.placeholder.nero-bot-token}"
      DEFAULT_RECIPIENT_TELEGRAM="448332502"
    '';
  };

  services.netdata = {
    enable = true;
    enableAnalyticsReporting = false;
    config = {
      web."bind to" = "127.0.0.1";
      db = {
        "dbengine tier 0 retention size" = "1GiB";
        "dbengine tier 1 retention size" = "1GiB";
        "dbengine tier 2 retention size" = "1GiB";
      };
    };
    configDir = {
      "health_alarm_notify.conf" = config.sops.templates."netdata-telegram".path;
      "health.d/disks.conf" = pkgs.writeText "nero-disk-alerts.conf" ''
        template: disk_space_usage
              on: disk.space
        chart labels: mount_point=/ /gnu
            calc: $used * 100 / ($avail + $used)
           units: %
           every: 1m
            warn: $this > 80
            crit: $this > 90
           delay: up 1m down 15m
         summary: Disk ''${label:mount_point} space usage
              to: sysadmin

        template: disk_inode_usage
              on: disk.inodes
        chart labels: mount_point=/ /gnu
            calc: $used * 100 / ($avail + $used)
           units: %
           every: 1m
            warn: $this > 80
            crit: $this > 90
           delay: up 1m down 15m
         summary: Disk ''${label:mount_point} inode usage
              to: sysadmin

        template: disk_fill_rate
              on: disk.space
        chart labels: mount_point=/ /gnu
          lookup: min -10m at -50m unaligned of avail
            calc: ($this - $avail) / (($now - $after) / 3600)
           units: GB/hour
           every: 1m

        template: out_of_disk_space_time
              on: disk.space
        chart labels: mount_point=/ /gnu
            calc: ($disk_fill_rate > 0) ? ($avail / $disk_fill_rate) : (inf)
           units: hours
           every: 10s
            warn: $this >= 0 and $this < 8
            crit: $this >= 0 and $this < 2
           delay: up 1m down 15m
         summary: Disk ''${label:mount_point} estimated time until full
              to: sysadmin
      '';
    };
  };

  systemd.services.netdata = {
    after = [ "sops-install-secrets.service" ];
    wants = [ "sops-install-secrets.service" ];
    restartTriggers = [ config.sops.templates."netdata-telegram".content ];
  };
}
