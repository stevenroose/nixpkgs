{ lib, pkgs, config, ... }:

let
  cfg = config.services.peertube;
in
{
  options.services.peertube = {
    enable = lib.mkEnableOption "Enable Peertube’s service";

    user = lib.mkOption {
      type = lib.types.str;
      default = "peertube";
      description = "System service and database user.";
    };

    configFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        The configuration file path for Peertube.
      '';
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
        ln -sf ${cfg.configFile} /var/lib/peertube/config/production.yaml
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

