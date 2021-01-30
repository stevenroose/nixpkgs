{ lib, pkgs, config, ... }:

let
  name = "peertube";
  cfg = config.services.peertube;

  uid = config.ids.uids.peertube;
  gid = config.ids.gids.peertube;
in
{
  options.services.peertube = {
    enable = lib.mkEnableOption "Enable Peertube’s service";

    user = lib.mkOption {
      type = lib.types.str;
      default = name;
      description = "User account under which Peertube runs";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = name;
      description = "Group under which Peertube runs";
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/${name}";
      description = ''
        The directory where Peertube stores its data.
      '';
    };

    database = lib.mkOption {
      type = lib.types.str;
      default = "peertube_prod";
      description = ''
        The Postgres database where Peertube stores its data.
      '';
    };

    configFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        The configuration file path for Peertube.
      '';
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
    users.users = lib.optionalAttrs (cfg.user == name) {
      "${name}" = {
        inherit uid;
        group = cfg.group;
        description = "Peertube user";
        home = cfg.dataDir;
        useDefaultShell = true;
        # todo: fix this. needed for postgres authentication
        password = "peertube";
      };
    };
    users.groups = lib.optionalAttrs (cfg.group == name) {
      "${name}" = {
        inherit gid;
      };
    };

    services.redis = {
      enable = true;
    };

    services.postgresql = {
      enable = true;
      package = pkgs.postgresql_12;
      # requires sudo -u postgres createdb -O peertube -E UTF8 -T template0 ${cfg.database}
      # so this may not suffice
      # ensureDatabases = [ "${cfg.database}" ];
      ensureUsers = [
        {
          name = "${cfg.user}";
          # we create database with `peertube` as owner in `preStart`
        }
      ];
      authentication = ''
        host ${cfg.database} ${cfg.user} 127.0.0.1/32 trust
        host ${cfg.database} ${cfg.user} 127.0.0.1/32 md5
      '';
    };

    # Make sure the datadir exists with the desired permissions.
    systemd.tmpfiles.rules = [
      "d \"${cfg.dataDir}\" - ${cfg.user} ${cfg.group} - -"
    ];

    systemd.services.peertube = {
      description = "Peertube";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" "postgresql.service" "redis.service" ];
      wants = [ "postgresql.service" "redis.service" ];

      environment.NODE_CONFIG_DIR = "${cfg.dataDir}/config";
      environment.NODE_ENV = "production";
      environment.HOME = cfg.package;

      path = [ pkgs.nodejs pkgs.bashInteractive pkgs.ffmpeg pkgs.openssl pkgs.sudo pkgs.youtube-dl ];

      script = ''
        install -m 0750 -d ${cfg.dataDir}/config
        ln -sf ${cfg.configFile} ${cfg.dataDir}/config/production.yaml
        exec npm start
      '';

      serviceConfig = {
        User = cfg.user;
        Group = cfg.group;
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

          if ! [ -e "${cfg.dataDir}/.first_run" ]; then
            set -v
            if [ -e "${cfg.dataDir}/.first_run_partial" ]; then
              echo "Warn: first run was interrupted"
            fi
            touch "${cfg.dataDir}/.first_run_partial"

            sudo -u postgres "${config.services.postgresql.package}/bin/createdb" -O ${cfg.user} -E UTF8 -T template0 ${cfg.database}
            sudo -u postgres "${config.services.postgresql.package}/bin/psql" -c "CREATE EXTENSION pg_trgm;" ${cfg.database}
            sudo -u postgres "${config.services.postgresql.package}/bin/psql" -c "CREATE EXTENSION unaccent;" ${cfg.database}

            touch "${cfg.dataDir}/.first_run"
            rm "${cfg.dataDir}/.first_run_partial"
          fi
        '';
        in "+${script}";
      };

      unitConfig.RequiresMountsFor = cfg.dataDir;
    };
  };
}

