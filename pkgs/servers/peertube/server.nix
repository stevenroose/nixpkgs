{ yarnModulesConfig, mkYarnModules', sources, version, nodejs, stdenv }:
rec {
  modules = mkYarnModules' rec {
    pname = "peertube-server-yarn-modules";
    inherit version;
    name = "${pname}-${version}";
    packageJSON = "${sources}/package.json";
    yarnLock = "${sources}/yarn.lock";
    pkgConfig = yarnModulesConfig;
  };
  dist = stdenv.mkDerivation {
    pname = "peertube-server";
    inherit version;
    src = sources;
    buildPhase = ''
      ln -s ${modules}/node_modules .
      patchShebangs scripts/build/server.sh
      npm run build:server
    '';
    installPhase = ''
      mkdir $out
      cp -a dist $out
    '';
    buildInputs = [ nodejs ];
  };
}
