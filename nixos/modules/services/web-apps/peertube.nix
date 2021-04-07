{ lib, pkgs, config, ... }:

let
  cfg = config.services.peertube;

  settingsFormat = pkgs.formats.yaml {};
  configFile = pkgs.writeText "production.yaml" ''
    listen:
      hostname: 'localhost'
      port: 9000

    webserver:
      https: true
      hostname: '${cfg.hostname}'
      port: 443

    database:
      hostname: '/run/postgresql'
      port: 5432
      ssl: false
      suffix: '_prod'
      username: 'peertube'
      password: 'peertube'
      pool:
        max: 5

    redis:
      hostname: 'localhost'
      port: 6379
      auth: null
      db: 0

    storage:
      tmp: '/var/lib/peertube/storage/tmp/'
      avatars: '/var/lib/peertube/storage/avatars/'
      videos: '/var/lib/peertube/storage/videos/'
      streaming_playlists: '/var/lib/peertube/storage/streaming-playlists/'
      redundancy: '/var/lib/peertube/storage/redundancy/'
      logs: '/var/lib/peertube/storage/logs/'
      previews: '/var/lib/peertube/storage/previews/'
      thumbnails: '/var/lib/peertube/storage/thumbnails/'
      torrents: '/var/lib/peertube/storage/torrents/'
      captions: '/var/lib/peertube/storage/captions/'
      cache: '/var/lib/peertube/storage/cache/'
      plugins: '/var/lib/peertube/storage/plugins/'
      client_overrides: '/var/lib/peertube/storage/client-overrides/'

    ${cfg.extraConfig}
  '';

in
{
  options.services.peertube = {
    enable = lib.mkEnableOption "Enable Peertube’s service";

    user = lib.mkOption {
      type = lib.types.str;
      default = "peertube";
      description = "System service and database user.";
    };

    hostname = lib.mkOption {
      type = lib.types.str;
      default = "example.com";
    };

    extraConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
    };

    database = {
      createLocally = lib.mkOption {
        description = "Configure local PostgreSQL database server for PeerTube.
          <warning>
            <para>
              You need to set <literal>database.hostname</literal> to <literal>/run/postgresql</literal> in the peertube configuration file.
            </para>
          </warning>
        ";
        type = lib.types.bool;
        default = true;
      };

      name = lib.mkOption {
        type = lib.types.str;
        default = "peertube_prod";
        description = "Database name.";
      };
    };

    smtp = {
      createLocally = lib.mkOption {
        description = "Configure local Postfix SMTP server for PeerTube.";
        type = lib.types.bool;
        default = true;
      };
    };

    redis = {
      createLocally = lib.mkOption {
        description = "Configure local Redis server for PeerTube.";
        type = lib.types.bool;
        default = true;
      };
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.peertube;
      description = ''
        Peertube package to use.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.postgresql = lib.mkIf cfg.database.createLocally {
      enable = true;
      ensureUsers = [ { name = cfg.user; }];
      # The database is created in the startup script of the peertube service.
    };

    services.postfix = lib.mkIf cfg.smtp.createLocally {
      enable = true;
    };

    services.redis = lib.mkIf cfg.redis.createLocally {
      enable = true;
    };

    systemd.services.peertube = {
      description = "Peertube";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" "postgresql.service" "redis.service" ];
      wants = [ "postgresql.service" "redis.service" ];

      environment.NODE_CONFIG_DIR = "/var/lib/peertube/config";
      environment.NODE_ENV = "production";
      environment.HOME = cfg.package;
      environment.NODE_EXTRA_CA_CERTS = "/etc/ssl/certs/ca-certificates.crt";

      path = [ pkgs.nodejs pkgs.bashInteractive pkgs.ffmpeg pkgs.openssl pkgs.sudo pkgs.youtube-dl ];

      script = ''
        install -m 0750 -d /var/lib/peertube/config
        ln -sf ${cfg.package}/config/default.yaml /var/lib/peertube/config/default.yaml
        ln -sf ${configFile} /var/lib/peertube/config/production.yaml
        exec npm start
      '';

      serviceConfig = {
        DynamicUser = true;
        User = cfg.user;
        Group = "peertube";
        WorkingDirectory = cfg.package;
        StateDirectory = "peertube";
        StateDirectoryMode = "0750";
        PrivateTmp = true;
        ProtectHome = true;
        ProtectControlGroups = true;
        ProtectSystem = "full";
        Restart = "always";
        Type = "simple";
        TimeoutSec = 60;
        CapabilityBoundingSet = "~CAP_SYS_ADMIN";
        ExecStartPre = let script = pkgs.writeScript "peertube-pre-start.sh" ''
          #!/bin/sh
          set -e

          if ! [ -e "/var/lib/peertube/.first_run" ]; then
            set -v
            if [ -e "/var/lib/peertube/.first_run_partial" ]; then
              echo "Warn: first run was interrupted"
            fi
            touch "/var/lib/peertube/.first_run_partial"

            echo "Running PeerTube's PostgreSQL initialization..."
            echo "PeerTube is known to work with PostgreSQL v12, if any error occurs, please check your version."

            sudo -u postgres "${config.services.postgresql.package}/bin/createdb" -O ${cfg.user} -E UTF8 -T template0 ${cfg.database.name}
            sudo -u postgres "${config.services.postgresql.package}/bin/psql" -c "CREATE EXTENSION pg_trgm;" ${cfg.database.name}
            sudo -u postgres "${config.services.postgresql.package}/bin/psql" -c "CREATE EXTENSION unaccent;" ${cfg.database.name}

            touch "/var/lib/peertube/.first_run"
            rm "/var/lib/peertube/.first_run_partial"
          fi
        '';
        in lib.mkIf cfg.database.createLocally "+${script}";
      };
    };
  };
}

