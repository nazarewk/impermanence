{ pkgs, config, lib, ... }:

with lib;
let
  cfg = config.home.persistence;

  persistentStorageNames = (filter (path: cfg.${path}.enable) (attrNames cfg));

  getDirPath = v: if isString v then v else v.directory;
  isBindfs = v: v.method == "bindfs";
  isSymlink = v:  v.method == "symlink";

  orderedDirs = lib.pipe cfg [
    (lib.attrsets.mapAttrsToList (persistentStorageName: conf:
      builtins.map (dir: { inherit persistentStorageName dir; }) conf.directories
    ))
    builtins.concatLists
    (builtins.sort (a: b: a.dir.directory < b.dir.directory))
  ];

  dirsByHomeMountpoint = lib.pipe orderedDirs [
    (builtins.map (e: {
      name = concatPaths [ config.home.homeDirectory e.dir.directory ];
      value = e;
    }))
    builtins.listToAttrs
  ];

  orderedFiles = lib.pipe cfg [
    (lib.attrsets.mapAttrsToList (persistentStorageName: conf:
      builtins.map (file: { inherit persistentStorageName file; }) conf.files
    ))
    builtins.concatLists
    (builtins.sort (a: b: a.file < b.file))
  ];

  inherit (pkgs.callPackage ./lib.nix { })
    splitPath
    dirListToPath
    concatPaths
    sanitizeName
    ;

  mount = "${pkgs.util-linux}/bin/mount";
  unmountScript = mountPoint: tries: sleep: ''
    triesLeft=${toString tries}
    if ${mount} | grep -F ${mountPoint}' ' >/dev/null; then
        while (( triesLeft > 0 )); do
            if fusermount -u ${mountPoint}; then
                break
            else
                (( triesLeft-- ))
                if (( triesLeft == 0 )); then
                    echo "Couldn't perform regular unmount of ${mountPoint}. Attempting lazy unmount."
                    fusermount -uz ${mountPoint}
                else
                    sleep ${toString sleep}
                fi
            fi
        done
    fi
  '';
in
{
  options = {

    home.persistence = mkOption {
      default = { };
      type = with types; attrsOf (
        submodule ({ name, ... }: {
          options =
            {
              persistentStoragePath = mkOption {
                type = path;
                default = name;
                description = ''
                  The path to persistent storage where the real
                  files and directories should be stored.
                '';
              };

              enable = mkOption {
                type = bool;
                default = true;
                description = "Whether to enable this persistent storage location.";
              };

              directories = mkOption {
                type = with types; listOf (either str (submodule {
                  options = {
                    directory = mkOption {
                      type = str;
                      default = null;
                      description = "The directory path to be linked.";
                    };
                    method = mkOption {
                      type = types.enum [ "bindfs" "symlink" ];
                      default = "bindfs";
                      description = ''
                        The linking method that should be used for this
                        directory. bindfs is the default and works for most use
                        cases, however some programs may behave better with
                        symlinks.
                      '';
                    };
                  };
                }));
                default = [ ];
                example = [
                  "Downloads"
                  "Music"
                  "Pictures"
                  "Documents"
                  "Videos"
                  "VirtualBox VMs"
                  ".gnupg"
                  ".ssh"
                  ".local/share/keyrings"
                  ".local/share/direnv"
                  {
                    directory = ".local/share/Steam";
                    method = "symlink";
                  }
                ];
                description = ''
                  A list of directories in your home directory that
                  you want to link to persistent storage. You may optionally
                  specify the linking method each directory should use.
                '';
                apply = builtins.map (directory: if !(builtins.isString directory) then directory else {
                  inherit directory;
                  method = "bindfs";
                });
              };

              files = mkOption {
                type = with types; listOf str;
                default = [ ];
                example = [
                  ".screenrc"
                ];
                description = ''
                  A list of files in your home directory you want to
                  link to persistent storage.
                '';
              };

              allowOther = mkOption {
                type = with types; nullOr bool;
                default = null;
                example = true;
                apply = x:
                  if x == null then
                    warn ''
                      home.persistence."${name}".allowOther not set; assuming 'false'.
                      See https://github.com/nix-community/impermanence#home-manager for more info.
                    ''
                      false
                  else
                    x;
                description = ''
                  Whether to allow other users, such as
                  <literal>root</literal>, access to files through the
                  bind mounted directories listed in
                  <literal>directories</literal>. Requires the NixOS
                  configuration parameter
                  <literal>programs.fuse.userAllowOther</literal> to
                  be <literal>true</literal>.
                '';
              };

              removePrefixDirectory = mkOption {
                type = types.bool;
                default = false;
                example = true;
                description = ''
                  Note: This is mainly useful if you have a dotfiles
                  repo structured for use with GNU Stow; if you don't,
                  you can likely ignore it.

                  Whether to remove the first directory when linking
                  or mounting; e.g. for the path
                  <literal>"screen/.screenrc"</literal>, the
                  <literal>screen/</literal> is ignored for the path
                  linked to in your home directory.
                '';
              };
            };
        })
      );
      description = ''
        A set of persistent storage location submodules listing the
        files and directories to link to their respective persistent
        storage location.

        Each attribute name should be the path relative to the user's
        home directory.

        For detailed usage, check the <link
        xlink:href="https://github.com/nix-community/impermanence">documentation</link>.
      '';
      example = literalExpression ''
        {
          "/persistent/home/talyz" = {
            directories = [
              "Downloads"
              "Music"
              "Pictures"
              "Documents"
              "Videos"
              "VirtualBox VMs"
              ".gnupg"
              ".ssh"
              ".nixops"
              ".local/share/keyrings"
              ".local/share/direnv"
              {
                directory = ".local/share/Steam";
                method = "symlink";
              }
            ];
            files = [
              ".screenrc"
            ];
            allowOther = true;
          };
        }
      '';
    };

  };

  config = {
    home.file =
      let
        link = file:
          pkgs.runCommand
            "${sanitizeName file}"
            { }
            "ln -s '${file}' $out";

        mkLinkNameValuePair = persistentStorageName: fileOrDir: {
          name =
            if cfg.${persistentStorageName}.removePrefixDirectory then
              dirListToPath (tail (splitPath [ fileOrDir ]))
            else
              fileOrDir;
          value = { source = link (concatPaths [ cfg.${persistentStorageName}.persistentStoragePath fileOrDir ]); };
        };

        mkLinksToPersistentStorage = persistentStorageName:
          listToAttrs (map
            (mkLinkNameValuePair persistentStorageName)
            (map getDirPath (cfg.${persistentStorageName}.files ++
              (filter isSymlink cfg.${persistentStorageName}.directories)))
          );
      in
      foldl' recursiveUpdate { } (map mkLinksToPersistentStorage persistentStorageNames);

    systemd.user.services =
      let
        mkBindMountService = persistentStorageName: dir:
          let
            mountDir =
              if cfg.${persistentStorageName}.removePrefixDirectory then
                dirListToPath (tail (splitPath [ dir ]))
              else
                dir;
            targetDir = escapeShellArg (concatPaths [ cfg.${persistentStorageName}.persistentStoragePath dir ]);
            mountPoint = escapeShellArg (concatPaths [ config.home.homeDirectory mountDir ]);
            name = "bindMount-${sanitizeName targetDir}";
            bindfsOptions = concatStringsSep "," (
              optional (!cfg.${persistentStorageName}.allowOther) "no-allow-other"
              ++ optional (versionAtLeast pkgs.bindfs.version "1.14.9") "fsname=${targetDir}"
            );
            bindfsOptionFlag = optionalString (bindfsOptions != "") (" -o " + bindfsOptions);
            bindfs = "bindfs" + bindfsOptionFlag;
            startScript = pkgs.writeShellScript name ''
              set -eu
              if ! mount | grep -F ${mountPoint}' ' && ! mount | grep -F ${mountPoint}/; then
                  mkdir -p ${mountPoint}
                  exec ${bindfs} ${targetDir} ${mountPoint}
              else
                  echo "There is already an active mount at or below ${mountPoint}!" >&2
                  exit 1
              fi
            '';
            stopScript = pkgs.writeShellScript "unmount-${name}" ''
              set -eu
              ${unmountScript mountPoint 6 5}
            '';
          in
          {
            inherit name;
            value = {
              Unit = {
                Description = "Bind mount ${targetDir} at ${mountPoint}";

                # Don't restart the unit, it could corrupt data and
                # crash programs currently reading from the mount.
                X-RestartIfChanged = false;

                # Don't add an implicit After=basic.target.
                DefaultDependencies = false;

                Before = [
                  "bluetooth.target"
                  "basic.target"
                  "default.target"
                  "paths.target"
                  "sockets.target"
                  "timers.target"
                ];


                After = lib.pipe dir [
                  # generate all system path prefixes
                  (lib.strings.splitString "/")
                  (pcs: builtins.map (i: lib.lists.sublist 0 i pcs) (lib.lists.range 0 (builtins.length pcs - 1)))
                  (builtins.map (lib.strings.concatStringsSep "/"))

                  # try to find an existing mountpoint for each generated path, skip those not found
                  (builtins.map (path: let homePath = concatPaths [ config.home.homeDirectory path ]; in dirsByHomeMountpoint.${homePath} or null))
                  (builtins.filter (e: e != null))

                  # replicate what `targetDir` & `name` do
                  (builtins.map (e: escapeShellArg (concatPaths [ cfg.${e.persistentStorageName}.persistentStoragePath e.dir.directory ])))
                  (builtins.map (path: "bindMount-${sanitizeName path}.service"))
                ];
              };

              Install.WantedBy = [ "paths.target" ];

              Service = {
                Type = "forking";
                ExecStart = "${startScript}";
                ExecStop = "${stopScript}";
                Environment = "PATH=${makeBinPath [ pkgs.coreutils pkgs.util-linux pkgs.gnugrep pkgs.bindfs ]}:/run/wrappers/bin";
              };
            };
          };

        mkBindMountServicesForPath = persistentStorageName:
          listToAttrs (map
            (mkBindMountService persistentStorageName)
            (map getDirPath (filter isBindfs cfg.${persistentStorageName}.directories))
          );
      in
      builtins.foldl'
        recursiveUpdate
        { }
        (map mkBindMountServicesForPath persistentStorageNames);

    home.activation =
      let
        dag = config.lib.dag;
        mount = "${pkgs.util-linux}/bin/mount";

        # The name of the activation script entry responsible for
        # reloading systemd user services. The name was initially
        # `reloadSystemD` but has been changed to `reloadSystemd`.
        reloadSystemd =
          if config.home.activation ? reloadSystemD then
            "reloadSystemD"
          else
            "reloadSystemd";

        mkBindMount = persistentStorageName: dir:
          let
            mountDir =
              if cfg.${persistentStorageName}.removePrefixDirectory then
                dirListToPath (tail (splitPath [ dir ]))
              else
                dir;
            targetDir = escapeShellArg (concatPaths [ cfg.${persistentStorageName}.persistentStoragePath dir ]);
            mountPoint = escapeShellArg (concatPaths [ config.home.homeDirectory mountDir ]);
            bindfsOptions = concatStringsSep "," (
              optional (!cfg.${persistentStorageName}.allowOther) "no-allow-other"
              ++ optional (versionAtLeast pkgs.bindfs.version "1.14.9") "fsname=${targetDir}"
            );
            bindfsOptionFlag = optionalString (bindfsOptions != "") (" -o " + bindfsOptions);
            bindfs = "${pkgs.bindfs}/bin/bindfs" + bindfsOptionFlag;
            systemctl = "XDG_RUNTIME_DIR=\${XDG_RUNTIME_DIR:-/run/user/$(id -u)} ${config.systemd.user.systemctlPath}";
          in
          ''
            mkdir -p ${targetDir}
            mkdir -p ${mountPoint}

            if ${mount} | grep -F ${mountPoint}' ' >/dev/null; then
                if ! ${mount} | grep -F ${mountPoint}' ' | grep -F bindfs; then
                    if ! ${mount} | grep -F ${mountPoint}' ' | grep -F ${targetDir}' ' >/dev/null; then
                        # The target directory changed, so we need to remount
                        echo "remounting ${mountPoint}"
                        ${systemctl} --user stop bindMount-${sanitizeName targetDir}
                        ${bindfs} ${targetDir} ${mountPoint}
                        mountedPaths[${mountPoint}]=1
                    fi
                fi
            elif ${mount} | grep -F ${mountPoint}/ >/dev/null; then
                echo "Something is mounted below ${mountPoint}, not creating bind mount to ${targetDir}" >&2
            else
                ${bindfs} ${targetDir} ${mountPoint}
                mountedPaths[${mountPoint}]=1
            fi
          '';

        mkUnmount = persistentStorageName: dir:
          let
            mountDir =
              if cfg.${persistentStorageName}.removePrefixDirectory then
                dirListToPath (tail (splitPath [ dir ]))
              else
                dir;
            mountPoint = escapeShellArg (concatPaths [ config.home.homeDirectory mountDir ]);
          in
          ''
            if [[ -n ''${mountedPaths[${mountPoint}]+x} ]]; then
              ${unmountScript mountPoint 3 1}
            fi
          '';

        mkLinkCleanup = persistentStorageName: dir:
          let
            mountDir =
              if cfg.${persistentStorageName}.removePrefixDirectory then
                dirListToPath (tail (splitPath [ dir ]))
              else
                dir;
            mountPoint = escapeShellArg (concatPaths [ config.home.homeDirectory mountDir ]);
          in
          ''
            # Unmount if it's mounted. Ensures smooth transition: bindfs -> symlink
            ${unmountScript mountPoint 3 1}

            # If it is a directory and it's empty
            if [ -d ${mountPoint} ] && [ -z "$(ls -A ${mountPoint})" ]; then
              echo "Removing empty directory ${mountPoint}"
              rm -d ${mountPoint}
            fi
          '';

        mkDirScripts = {filterFn, mapFn, reverse ? false}: lib.pipe orderedDirs [
          (builtins.filter (e: filterFn e.dir))
          (builtins.map ({persistentStorageName, dir}: mapFn persistentStorageName dir.directory))
          (if reverse then lib.lists.reverseList else (x: x))
          (builtins.concatStringsSep "\n")
        ];
      in
      mkMerge [
        (mkIf (any (path: (filter isSymlink cfg.${path}.directories) != [ ]) persistentStorageNames) {
          # Clean up existing empty directories in the way of links
          cleanEmptyLinkTargets =
            dag.entryBefore
              [ "checkLinkTargets" ]
              (mkDirScripts {filterFn = isBindfs; mapFn = mkLinkCleanup; reverse = true; });
        })
        (mkIf (any (path: (filter isBindfs cfg.${path}.directories) != [ ]) persistentStorageNames) {
          createAndMountPersistentStoragePaths =
            dag.entryBefore
              [ "writeBoundary" ]
              ''
                declare -A mountedPaths
                ${mkDirScripts {filterFn = isBindfs; mapFn = mkBindMount; reverse = false; }}
              '';

          unmountPersistentStoragePaths =
            dag.entryBefore
              [ "createAndMountPersistentStoragePaths" ]
              ''
                PATH=$PATH:/run/wrappers/bin
                unmountBindMounts() {
                ${mkDirScripts {filterFn = isBindfs; mapFn = mkUnmount; reverse = true; }}
                }

                # Run the unmount function on error to clean up stray
                # bind mounts
                trap "unmountBindMounts" ERR
              '';

          runUnmountPersistentStoragePaths =
            dag.entryBefore
              [ reloadSystemd ]
              ''
                unmountBindMounts
              '';
        })
        (mkIf (any (path: (cfg.${path}.files != [ ]) || ((filter isSymlink cfg.${path}.directories) != [ ])) persistentStorageNames) {
          createTargetFileDirectories =
            dag.entryBefore
              [ "writeBoundary" ]
              (lib.pipe (orderedFiles ++ (builtins.filter (d: isSymlink d.dir) orderedDirs)) [
                (builtins.map ({persistentStorageName, ...}@e: lib.pipe (e.file or e.dir.directory) [
                  dirOf
                  (path: concatPaths [
                    cfg.${persistentStorageName}.persistentStoragePath
                    path
                  ])
                ]))
                (builtins.sort (a: b: a < b))
                lib.lists.unique
                (builtins.map (path: ''mkdir -p ${escapeShellArg path}''))
                (builtins.concatStringsSep "\n")
              ]);
        })
      ];
  };

}
