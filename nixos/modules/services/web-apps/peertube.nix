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
      hostname: '${cfg.database.host}'
      port: '${toString cfg.database.port}'
      name: '${cfg.database.name}'
      username: '${cfg.database.user}'
      ssl: true

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

      host = lib.mkOption {
        type = lib.types.str;
        default = "/run/postgresql";
        example = "192.168.15.47";
        description = "Database host address or unix socket.";
      };

      port = lib.mkOption {
        type = lib.types.int;
        default = 5432;
        description = "Database host port.";
      };

      user = lib.mkOption {
        type = lib.types.str;
        default = "peertube";
        description = "Database user.";
      };

      name = lib.mkOption {
        type = lib.types.str;
        default = "peertube";
        description = "Database name.";
      };

      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        example = "/run/keys/peertube-db-password";
        description = ''
          A file containing the password corresponding to
          <option>database.user</option>.
        '';
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
      after = [ "network.target" "redis.service" ] ++ lib.optionals cfg.database.createLocally [ "postgresql.service" ];
      wants = [ "redis.service" ] ++ lib.optionals cfg.database.createLocally [ "postgresql.service" ];

      environment.NODE_CONFIG_DIR = "/var/lib/peertube/config";
      environment.NODE_ENV = "production";
      environment.HOME = cfg.package;
      environment.NODE_EXTRA_CA_CERTS = "/etc/ssl/certs/ca-certificates.crt";

      path = [ pkgs.nodejs pkgs.bashInteractive pkgs.ffmpeg pkgs.openssl pkgs.sudo pkgs.youtube-dl ];

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
        ExecStart = let script = pkgs.writeScript "peertube-start.sh" ''
          #!/bin/sh
          set -e

          install -m 0750 -d /var/lib/peertube/config
          ln -sf ${cfg.package}/config/default.yaml /var/lib/peertube/config/default.yaml
          ln -sf ${configFile} /var/lib/peertube/config/production.yaml
          exec npm start
        '';
        in "${script}";
      } // (lib.optionalAttrs (!cfg.database.createLocally) {
        ExecStartPre = let preStartScript = pkgs.writeScript "peertube-pre-start.sh" ''
          #!/bin/sh
          set -e

          cat > ${cfg.runtimeDir}/config/local-production.yaml <<EOF
          database:
            password: '$(cat ${cfg.database.passwordFile})'
          EOF
        '';
        in "${preStartScript}";
      }) // (lib.optionalAttrs cfg.database.createLocally {
        ExecStartPre = let
          psqlSetupCommands = pkgs.writeText "test.sql" ''
            SELECT 'CREATE USER "${cfg.database.user}"' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${cfg.database.user}')\gexec
            SELECT 'CREATE DATABASE "${cfg.database.name}" OWNER "${cfg.database.user}" TEMPLATE template0 ENCODING UTF8' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${cfg.database.name}')\gexec
            \c '${cfg.database.name}'
            CREATE EXTENSION IF NOT EXISTS pg_trgm;
            CREATE EXTENSION IF NOT EXISTS unaccent;
          '';
          preStartScript = pkgs.writeScript "peertube-pre-start.sh" ''
            #!/bin/sh
            set -e

            sudo -u postgres "${config.services.postgresql.package}/bin/psql" -f ${psqlSetupCommands}
          '';
        in "+${preStartScript}";
      });
    };
  };
}

