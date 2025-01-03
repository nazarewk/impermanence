{ pkgs, config, lib, utils, ... }:

let
  inherit (lib)
    all
    any
    attrNames
    attrValues
    catAttrs
    concatMap
    concatMapStrings
    concatMapStringsSep
    concatStringsSep
    elem
    escapeShellArg
    escapeShellArgs
    filter
    filterAttrs
    flatten
    foldl'
    hasPrefix
    id
    intersectLists
    listToAttrs
    literalExpression
    mapAttrs
    mapAttrsToList
    mkAfter
    mkDefault
    mkIf
    mkMerge
    mkOption
    optional
    optionalString
    pipe
    types
    unique
    zipAttrsWith
    ;

  inherit (utils)
    escapeSystemdPath
    fsNeededForBoot
    ;

  inherit (pkgs.callPackage ./lib.nix { })
    concatPaths
    duplicates
    parentsOf
    isParentOf
    ;

  scripts = pkgs.callPackage ./scripts { };

  cfg = config.impermanence;
  cfgs = config.environment.persistence;
  users = config.users.users;

  allFileSystems = lib.attrsets.recursiveUpdate config.virtualisation.fileSystems config.fileSystems;
  enabledPersistences = filter (v: v.enable) (attrValues cfgs);
  allPersistentStoragePaths = zipAttrsWith (_name: flatten) enabledPersistences;
  allSystemFiles = allPersistentStoragePaths.files;
  allSystemDirectories = allPersistentStoragePaths.directories;

  # Create fileSystems bind mount entry.
  mkBindMountNameValuePair = { dirPath, persistentStoragePath, hideMount, ... }: {
    name = concatPaths [ "/" dirPath ];
    value = {
      device = concatPaths [ persistentStoragePath dirPath ];
      noCheck = true;
      options = [ "bind" "X-fstrim.notrim" ]
        ++ optional hideMount "x-gvfs-hide";
      depends = [ persistentStoragePath ];
    };
  };

  # Create all fileSystems bind mount entries for a specific
  # persistent storage path.
  bindMounts = listToAttrs (map mkBindMountNameValuePair allSystemDirectories);

  systemMountPoints = lib.pipe allFileSystems [
    builtins.attrValues
    (builtins.map (fs: fs.mountPoint))
  ];
  getMountDependencies = persistentStoragePath: mountPath:
    let
      toMountUnit = path: "${escapeSystemdPath path}.mount";
      persistentPath = concatPaths [ persistentStoragePath mountPath ];
      getParentMount = path:
        let dir = dirOf path; in pipe systemMountPoints [
          (builtins.filter (mountPoint: hasPrefix mountPoint dir))
          (builtins.sort builtins.lessThan)
          lib.lists.last
        ];
      persistentParent = getParentMount persistentPath;
      mountParent = getParentMount mountPath;
      parent = dirOf mountPath;
    in
    rec {
      persistentPaths = [ persistentParent ];
      mountPaths = [ mountParent ];
      mountServices = [ "${mkCreateDirectoryUnitName parent persistentStoragePath}.service" ];
      persistentUnits = builtins.map toMountUnit persistentPaths;
      mountUnits = builtins.map toMountUnit mountPaths ++ mountServices;
    };

  # All directories in the order they should be created.
  allOrderedDirectories =
    let
      # All the directories actually listed by the user and the
      # parent directories of listed files.
      explicitDirectories = allSystemDirectories ++ (unique (catAttrs "parentDirectory" allSystemFiles));

      # Home directories have to be handled specially, since
      # they're at the permissions boundary where they
      # themselves should be owned by the user and have stricter
      # permissions than regular directories, whereas its parent
      # should be owned by root and have regular permissions.
      #
      # This simply collects all the home directories and sets
      # the appropriate permissions and ownership.
      homeDirectories =
        foldl'
          (state: dirCfg:
            let
              defaultPerms = {
                mode = cfg.userDefaultPerms.mode;
                user = dirCfg.user;
                group = users.${dirCfg.user}.group;
              };
              homeDir = {
                directory = dirCfg.home;
                dirPath = dirCfg.home;
                home = null;
                isHomeDir = true;
                inherit (defaultPerms)
                  mode
                  user
                  group
                  ;
                inherit defaultPerms;
                inherit (dirCfg)
                  persistentStoragePath
                  enableDebugging
                  enableActivationScript
                  ;
              };
            in
            state
            ++ lib.lists.optional (dirCfg.home != null && !(elem homeDir state)) homeDir
          )
          [ ]
          explicitDirectories;

      # Generate entries for all parent directories of the
      # argument directories, listed in the order they need to
      # be created. The parent directories are assigned default
      # permissions.
      mkParentDirectories = dirCfgs:
        let
          # Create a new directory item from `dir`, the child
          # directory item to inherit properties from and
          # `path`, the parent directory path.
          mkParent = dirCfg: path: {
            directory = path;
            dirPath = path;
            inherit (dirCfg)
              persistentStoragePath
              home
              enableDebugging
              enableActivationScript
              ;
            inherit (dirCfg.defaultPerms)
              user
              group
              mode
              ;
          } // lib.optionalAttrs (dirCfg.home != null) {
            dirPath = concatPaths [ dirCfg.home path ];
          } // lib.optionalAttrs ((dirCfg.isHomeDir or false) && isParentOf path dirCfg.dirPath) {
            # make /home consistently owned by root
            inherit (cfg.homeParentPerms)
              user
              group
              mode
              ;
          };

          # Create new directory items for all parent
          # directories of a directory.
          mkParents = dirCfg:
            map (mkParent dirCfg) (parentsOf dirCfg.directory);
        in
        map mkParents dirCfgs;
    in
    lib.pipe [
      # Parent directories of home folders. This is usually only
      # /home, unless the user's home is in a non-standard
      # location.
      (mkParentDirectories homeDirectories)
      homeDirectories
      # Parent directories of all explicitly listed directories.
      (mkParentDirectories explicitDirectories)
      explicitDirectories
    ] [
      flatten
      unique
      (builtins.sort (a: b: builtins.lessThan a.dirPath b.dirPath))
    ];

  mkCommandDirWithPerms =
    { dirPath
    , persistentStoragePath
    , user
    , group
    , mode
    , ...
    }:
    escapeShellArgs [
      (lib.getExe scripts.os.create-directories)
      persistentStoragePath
      dirPath
      user
      group
      mode
    ];

  mkCommandPersistFile = { filePath, persistentStoragePath, ... }:
    let
      mountPoint = filePath;
      targetFile = concatPaths [ persistentStoragePath filePath ];
    in
    escapeShellArgs [
      (lib.getExe scripts.os.mount-file)
      mountPoint
      targetFile
    ];

  mkCreateDirectoryUnitName = path: persistentStoragePath: "impermanence-mkdir--${escapeSystemdPath persistentStoragePath}--${escapeSystemdPath path}";
in
{
  options = {

    impermanence.defaultEnableActivationScript = mkOption {
      type = with types; bool;
      default = true;
    };
    impermanence.userDefaultPerms.mode = mkOption {
      type = with types; str;
      default = "0755";
    };

    impermanence.defaultPerms.mode = mkOption {
      type = with types; str;
      default = "0755";
    };
    impermanence.defaultPerms.user = mkOption {
      type = with types; str;
      default = "root";
    };
    impermanence.defaultPerms.group = mkOption {
      type = with types; str;
      default = "root";
    };

    impermanence.homeParentPerms.mode = mkOption {
      type = with types; str;
      default = cfg.defaultPerms.mode;
    };
    impermanence.homeParentPerms.user = mkOption {
      type = with types; str;
      default = cfg.defaultPerms.user;
    };
    impermanence.homeParentPerms.group = mkOption {
      type = with types; str;
      default = "users";
    };

    environment.persistence = mkOption {
      default = { };
      type =
        let
          inherit (types)
            attrsOf
            bool
            listOf
            submodule
            nullOr
            path
            str
            coercedTo
            ;
        in
        attrsOf (
          submodule (
            { name, ... }@persistenceArgs:
            let
              persistenceCfg = persistenceArgs.config;
              defaultPerms = cfg.defaultPerms;
              commonOpts = {
                options = {
                  persistentStoragePath = mkOption {
                    type = path;
                    default = persistenceCfg.persistentStoragePath;
                    defaultText = "environment.persistence.‹name›.persistentStoragePath";
                    description = ''
                      The path to persistent storage where the real
                      file or directory should be stored.
                    '';
                  };
                  home = mkOption {
                    type = nullOr path;
                    default = null;
                    internal = true;
                    description = ''
                      The path to the home directory the file is
                      placed within.
                    '';
                  };
                  enableDebugging = mkOption {
                    type = bool;
                    default = persistenceCfg.enableDebugging;
                    defaultText = "environment.persistence.‹name›.enableDebugging";
                    internal = true;
                    description = ''
                      Enable debug trace output when running
                      scripts. You only need to enable this if asked
                      to.
                    '';
                  };

                  enableActivationScript = mkOption {
                    type = bool;
                    default = persistenceCfg.enableActivationScript;
                    defaultText = "environment.persistence.‹name›.enableActivationScript";
                    internal = true;
                    description = ''
                      Enable mounting in an activation script.
                    '';
                  };
                };
              };
              dirPermsOpts = {
                user = mkOption {
                  type = str;
                  description = ''
                    If the directory doesn't exist in persistent
                    storage it will be created and owned by the user
                    specified by this option.
                  '';
                };
                group = mkOption {
                  type = str;
                  description = ''
                    If the directory doesn't exist in persistent
                    storage it will be created and owned by the
                    group specified by this option.
                  '';
                };
                mode = mkOption {
                  type = str;
                  example = "0700";
                  description = ''
                    If the directory doesn't exist in persistent
                    storage it will be created with the mode
                    specified by this option.
                  '';
                };
              };
              fileOpts = {
                options = {
                  file = mkOption {
                    type = str;
                    description = ''
                      The path to the file.
                    '';
                  };
                  parentDirectory =
                    commonOpts.options //
                    mapAttrs
                      (_: x:
                        if x._type or null == "option" then
                          x // { internal = true; }
                        else
                          x)
                      dirOpts.options;
                  filePath = mkOption {
                    type = path;
                    internal = true;
                  };
                };
              };
              dirOpts = {
                options = {
                  directory = mkOption {
                    type = str;
                    description = ''
                      The path to the directory.
                    '';
                  };
                  hideMount = mkOption {
                    type = bool;
                    default = persistenceCfg.hideMounts;
                    defaultText = "environment.persistence.‹name›.hideMounts";
                    example = true;
                    description = ''
                      Whether to hide bind mounts from showing up as
                      mounted drives.
                    '';
                  };
                  # Save the default permissions at the level the
                  # directory resides. This used when creating its
                  # parent directories, giving them reasonable
                  # default permissions unaffected by the
                  # directory's own.
                  defaultPerms = mapAttrs (_: x: x // { internal = true; }) dirPermsOpts;
                  dirPath = mkOption {
                    type = path;
                    internal = true;
                  };
                } // dirPermsOpts;
              };
              rootFile = submodule [
                commonOpts
                fileOpts
                (fileArgs:
                  let fileCfg = fileArgs.config; in {
                    parentDirectory = mkDefault (defaultPerms // rec {
                      directory = dirOf fileCfg.file;
                      dirPath = directory;
                      inherit (fileCfg) persistentStoragePath;
                      inherit defaultPerms;
                    });
                    filePath = mkDefault fileCfg.file;
                  })
              ];
              rootDir = submodule ([
                commonOpts
                dirOpts
                (dirArgs:
                  let dirCfg = dirArgs.config; in {
                    defaultPerms = mkDefault defaultPerms;
                    dirPath = mkDefault dirCfg.directory;
                  })
              ] ++ (mapAttrsToList (n: v: { ${n} = mkDefault v; }) defaultPerms));
            in
            {
              options =
                {
                  enable = mkOption {
                    type = bool;
                    default = true;
                    description = "Whether to enable this persistent storage location.";
                  };

                  persistentStoragePath = mkOption {
                    type = path;
                    default = name;
                    defaultText = "‹name›";
                    description = ''
                      The path to persistent storage where the real
                      files and directories should be stored.
                    '';
                  };

                  users = mkOption {
                    type = attrsOf (
                      submodule (
                        { name, ... }@userArgs:
                        let
                          userCfg = userArgs.config;

                          userDefaultPerms = {
                            mode = cfg.userDefaultPerms.mode;
                            user = name;
                            group = users.${userDefaultPerms.user}.group;
                          };
                          fileConfig = fileArgs:
                            let fileCfg = fileArgs.config; in {
                              parentDirectory = rec {
                                directory = dirOf fileCfg.file;
                                dirPath = concatPaths [ fileCfg.home directory ];
                                inherit (fileCfg) persistentStoragePath home;
                                defaultPerms = mkDefault userDefaultPerms;
                              };
                              filePath = concatPaths [ fileCfg.home fileCfg.file ];
                            };
                          userFile = submodule [
                            commonOpts
                            fileOpts
                            { inherit (userCfg) home; }
                            {
                              parentDirectory = mkDefault userDefaultPerms;
                            }
                            fileConfig
                          ];
                          dirConfig = dirArgs:
                            let dirCfg = dirArgs.config; in {
                              defaultPerms = mkDefault userDefaultPerms;
                              dirPath = concatPaths [ dirCfg.home dirCfg.directory ];
                            };
                          userDir = submodule ([
                            commonOpts
                            dirOpts
                            { inherit (userCfg) home; }
                            dirConfig
                          ] ++ (mapAttrsToList (n: v: { ${n} = mkDefault v; }) userDefaultPerms));
                        in
                        {
                          options =
                            {
                              # Needed because defining fileSystems
                              # based on values from users.users
                              # results in infinite recursion.
                              home = mkOption {
                                type = path;
                                default = "/home/${userDefaultPerms.user}";
                                defaultText = "/home/<username>";
                                description = ''
                                  The user's home directory. Only
                                  useful for users with a custom home
                                  directory path.

                                  Cannot currently be automatically
                                  deduced due to a limitation in
                                  nixpkgs.
                                '';
                              };

                              files = mkOption {
                                type = listOf (coercedTo str (f: { file = f; }) userFile);
                                default = [ ];
                                example = [
                                  ".screenrc"
                                ];
                                description = ''
                                  Files that should be stored in
                                  persistent storage.
                                '';
                              };

                              directories = mkOption {
                                type = listOf (coercedTo str (d: { directory = d; }) userDir);
                                default = [ ];
                                example = [
                                  "Downloads"
                                  "Music"
                                  "Pictures"
                                  "Documents"
                                  "Videos"
                                ];
                                description = ''
                                  Directories to bind mount to
                                  persistent storage.
                                '';
                              };
                            };
                        }
                      )
                    );
                    default = { };
                    description = ''
                      A set of user submodules listing the files and
                      directories to link to their respective user's
                      home directories.

                      Each attribute name should be the name of the
                      user.

                      For detailed usage, check the <link
                      xlink:href="https://github.com/nix-community/impermanence">documentation</link>.
                    '';
                    example = literalExpression ''
                      {
                        talyz = {
                          directories = [
                            "Downloads"
                            "Music"
                            "Pictures"
                            "Documents"
                            "Videos"
                            "VirtualBox VMs"
                            { directory = ".gnupg"; mode = "0700"; }
                            { directory = ".ssh"; mode = "0700"; }
                            { directory = ".nixops"; mode = "0700"; }
                            { directory = ".local/share/keyrings"; mode = "0700"; }
                            ".local/share/direnv"
                          ];
                          files = [
                            ".screenrc"
                          ];
                        };
                      }
                    '';
                  };

                  files = mkOption {
                    type = listOf (coercedTo str (f: { file = f; }) rootFile);
                    default = [ ];
                    example = [
                      "/etc/machine-id"
                      "/etc/nix/id_rsa"
                    ];
                    description = ''
                      Files that should be stored in persistent storage.
                    '';
                  };

                  directories = mkOption {
                    type = listOf (coercedTo str (d: { directory = d; }) rootDir);
                    default = [ ];
                    example = [
                      "/var/log"
                      "/var/lib/bluetooth"
                      "/var/lib/nixos"
                      "/var/lib/systemd/coredump"
                      "/etc/NetworkManager/system-connections"
                    ];
                    description = ''
                      Directories to bind mount to persistent storage.
                    '';
                  };

                  hideMounts = mkOption {
                    type = bool;
                    default = false;
                    example = true;
                    description = ''
                      Whether to hide bind mounts from showing up as mounted drives.
                    '';
                  };

                  enableDebugging = mkOption {
                    type = bool;
                    default = false;
                    internal = true;
                    description = ''
                      Enable debug trace output when running
                      scripts. You only need to enable this if asked
                      to.
                    '';
                  };

                  enableActivationScript = mkOption {
                    type = bool;
                    default = cfg.defaultEnableActivationScript;
                    defaultText = "impermanence.enableActivationScript";
                    internal = true;
                    description = ''
                      Enable mounting in an activation script.
                    '';
                  };

                  enableWarnings = mkOption {
                    type = bool;
                    default = true;
                    description = ''
                      Enable non-critical warnings.
                    '';
                  };
                };
              config =
                let
                  allUsers = zipAttrsWith (_name: flatten) (attrValues persistenceCfg.users);
                in
                {
                  files = allUsers.files or [ ];
                  directories = allUsers.directories or [ ];
                };
            }
          )
        );
      description = ''
        A set of persistent storage location submodules listing the
        files and directories to link to their respective persistent
        storage location.

        Each attribute name should be the full path to a persistent
        storage location.

        For detailed usage, check the <link
        xlink:href="https://github.com/nix-community/impermanence">documentation</link>.
      '';
      example = literalExpression ''
        {
          "/persistent" = {
            directories = [
              "/var/log"
              "/var/lib/bluetooth"
              "/var/lib/nixos"
              "/var/lib/systemd/coredump"
              "/etc/NetworkManager/system-connections"
              { directory = "/var/lib/colord"; user = "colord"; group = "colord"; mode = "u=rwx,g=rx,o="; }
            ];
            files = [
              "/etc/machine-id"
              { file = "/etc/nix/id_rsa"; parentDirectory = { mode = "u=rwx,g=,o="; }; }
            ];
          };
          users.talyz = { ... }; # See the dedicated example
        }
      '';
    };

    # Forward declare a dummy option for VM filesystems since the real one won't exist
    # unless the VM module is actually imported.
    virtualisation.fileSystems = mkOption { };
  };

  config = mkIf (allPersistentStoragePaths != { }) (mkMerge [{
    systemd.targets.impermanence-mounts = {
      description = "nix/impermanence: all mounts finished";
      wantedBy = [ "default.target" ];
    };

    systemd.services =
      let
        mkPersistFileService = { filePath, persistentStoragePath, enableDebugging, ... }:
          let
            targetFile = concatPaths [ persistentStoragePath filePath ];
            mountPoint = escapeShellArg filePath;
            deps = getMountDependencies persistentStoragePath filePath;
          in
          {
            "impermanence-persist-file--${escapeSystemdPath (escapeShellArg targetFile)}" = {
              description = "nix/impermanence: bind mount or link ${escapeShellArg targetFile} to ${mountPoint}";
              before = [ "impermanence-mounts.target" ];
              requiredBy = [ "impermanence-mounts.target" ];
              wantedBy = deps.mountUnits;
              wants = deps.persistentUnits;
              after = deps.mountUnits ++ deps.persistentUnits;
              path = [ pkgs.util-linux ];
              unitConfig.DefaultDependencies = false;
              environment.DEBUG = builtins.toString enableDebugging;
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
                ExecStart = mkCommandPersistFile { inherit filePath persistentStoragePath; };
                ExecStop = pkgs.writeShellScript "unbindOrUnlink-${escapeSystemdPath (escapeShellArg targetFile)}" ''
                  set -eu
                  if [[ -L ${mountPoint} ]]; then
                      rm ${mountPoint}
                  else
                      umount ${mountPoint}
                      rm ${mountPoint}
                  fi
                '';
              };
            };
          };
        mkDirectoryService = { dirPath, persistentStoragePath, enableDebugging, ... }@dirCfg:
          let
            deps = getMountDependencies persistentStoragePath dirPath;
          in
          {
            "${mkCreateDirectoryUnitName dirPath persistentStoragePath}" = {
              description = "nix/impermanence: create ${escapeShellArg dirPath} directory inside ${escapeShellArg persistentStoragePath}";
              before = [ "impermanence-mounts.target" ];
              requiredBy = [ "impermanence-mounts.target" ];
              wantedBy = deps.mountUnits;
              wants = deps.persistentUnits;
              after = deps.mountUnits ++ deps.persistentUnits;
              unitConfig.DefaultDependencies = false;
              environment.DEBUG = builtins.toString enableDebugging;
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
                ExecStart = mkCommandDirWithPerms dirCfg;
              };
            };
          };

        allServiceDirectories = pipe allOrderedDirectories [
          (builtins.filter (dirCfg: !(lib.strings.hasSuffix "/." dirCfg.dirPath)))
        ];
      in
      mkMerge (
        [ ]
        ++ map mkDirectoryService allServiceDirectories
        ++ map mkPersistFileService allSystemFiles
      );

    fileSystems = mkIf (allSystemDirectories != [ ]) bindMounts;
    # So the mounts still make it into a VM built from `system.build.vm`
    virtualisation.fileSystems = mkIf (allSystemDirectories != [ ]) bindMounts;

    system.activationScripts =
      let
        activationFiles = lib.pipe allSystemFiles [
          (builtins.filter (fileCfg: fileCfg.enableActivationScript))
        ];
        activationDirectories = lib.pipe allOrderedDirectories [
          (builtins.filter (dirCfg:
            dirCfg.enableActivationScript
            || (
              builtins.any
                (fileCfg: lib.strings.hasPrefix fileCfg.filePath dirCfg.dirPath)
                activationFiles
            ))
          )
        ];
      in
      {
        "impermanenceCreatePersistentStorageDirs" = {
          deps = [ "users" "groups" ];
          # Build an activation script which creates all persistent
          # storage directories we want to bind mount.
          text = builtins.toString (pkgs.writeShellScript "impermanence-run-create-directories" ''
            _status=0
            trap "_status=1" ERR
            ${concatMapStrings (dirCfg: "DEBUG=${builtins.toString dirCfg.enableDebugging} ${mkCommandDirWithPerms dirCfg}\n") activationDirectories}
            exit $_status
          '');
        };
        "impermanencePersistFiles" = {
          deps = [ "impermanenceCreatePersistentStorageDirs" ];
          text = builtins.toString (pkgs.writeShellScript "impermanence-persist-files" ''
            _status=0
            trap "_status=1" ERR
            ${concatMapStrings (fileCfg: "DEBUG=${builtins.toString fileCfg.enableDebugging} ${mkCommandPersistFile fileCfg}\n") activationFiles}
            exit $_status
          '');
        };
      };

    # Create the mountpoints of directories marked as needed for boot
    # which are also persisted. For this to work, it has to run at
    # early boot, before NixOS' filesystem mounting runs. Without
    # this, initial boot fails when for example /var/lib/nixos is
    # persisted but not created in persistent storage.
    boot.initrd =
      let
        neededForBootFs = catAttrs "mountPoint" (filter fsNeededForBoot (attrValues allFileSystems));
        neededForBootDirs = filter (dir: elem dir.dirPath neededForBootFs) allSystemDirectories;
        getDevice = fs: if fs.device != null then fs.device else "/dev/disk/by-label/${fs.label}";
        mkMount = fs:
          let
            mountPoint = concatPaths [ "/persist-tmp-mnt" fs.mountPoint ];
            device = getDevice fs;
            options = filter (o: (builtins.match "(x-.*\.mount)" o) == null) fs.options;
            optionsFlag = optionalString (options != [ ]) ("-o " + escapeShellArg (concatStringsSep "," options));
          in
          ''
            mkdir -p ${escapeShellArg mountPoint}
            mount -t ${escapeShellArgs [ fs.fsType device mountPoint ]} ${optionsFlag}
          '';
        mkDir = { persistentStoragePath, dirPath, ... }: ''
          mkdir -p ${escapeShellArg (concatPaths [ "/persist-tmp-mnt" persistentStoragePath dirPath ])}
        '';
        mkUnmount = fs: ''
          umount ${escapeShellArg (concatPaths [ "/persist-tmp-mnt" fs.mountPoint ])}
        '';
        fileSystems =
          let
            persistentStoragePaths = unique (catAttrs "persistentStoragePath" allSystemDirectories);
            matchFileSystems = fs: attrValues (filterAttrs (_: v: v.mountPoint or null == fs) allFileSystems);
          in
          concatMap matchFileSystems persistentStoragePaths;
        deviceUnits = unique
          (map
            (fs:
              if fs.fsType == "zfs" then
                "zfs-import.target"
              else
                "${(escapeSystemdPath (getDevice fs))}.device")
            fileSystems);
        createNeededForBootDirs = ''
          ${concatMapStrings mkMount fileSystems}
          ${concatMapStrings mkDir neededForBootDirs}
          ${concatMapStrings mkUnmount fileSystems}
        '';
      in
      {
        systemd.services = mkIf config.boot.initrd.systemd.enable {
          create-needed-for-boot-dirs = {
            wantedBy = [ "initrd-root-device.target" ];
            requires = deviceUnits;
            after = deviceUnits;
            before = [ "sysroot.mount" ];
            serviceConfig.Type = "oneshot";
            unitConfig.DefaultDependencies = false;
            script = createNeededForBootDirs;
          };
        };
        postDeviceCommands = mkIf (!config.boot.initrd.systemd.enable)
          (mkAfter createNeededForBootDirs);
      };

    assertions =
      let
        markedNeededForBoot = cond: fs:
          if allFileSystems ? ${fs} then
            allFileSystems.${fs}.neededForBoot == cond
          else
            cond;
        persistentStoragePaths = attrNames cfgs;
        usersPerPath = allPersistentStoragePaths.users;
        homeDirOffenders =
          filterAttrs
            (n: v: (v.home != config.users.users.${n}.home));
      in
      [
        {
          # Assert that all persistent storage volumes we use are
          # marked with neededForBoot.
          assertion = all (markedNeededForBoot true) persistentStoragePaths;
          message =
            let
              offenders = filter (markedNeededForBoot false) persistentStoragePaths;
            in
            ''
              environment.persistence:
                  All filesystems used for persistent storage must
                  have the flag neededForBoot set to true.

                  Please fix or remove the following paths:
                    ${concatStringsSep "\n      " offenders}
            '';
        }
        {
          assertion = all (users: (homeDirOffenders users) == { }) usersPerPath;
          message =
            let
              offendersPerPath = filter (users: (homeDirOffenders users) != { }) usersPerPath;
              offendersText =
                concatMapStringsSep
                  "\n      "
                  (offenders:
                    concatMapStringsSep
                      "\n      "
                      (n: "${n}: ${offenders.${n}.home} != ${config.users.users.${n}.home}")
                      (attrNames offenders))
                  offendersPerPath;
            in
            ''
              environment.persistence:
                  Users and home doesn't match:
                    ${offendersText}

                  You probably want to set each
                  environment.persistence.<path>.users.<user>.home to
                  match the respective user's home directory as
                  defined by users.users.<user>.home.
            '';
        }
        {
          assertion = duplicates (catAttrs "filePath" allSystemFiles) == [ ];
          message =
            let
              offenders = duplicates (catAttrs "filePath" allSystemFiles);
            in
            ''
              environment.persistence:
                  The following files were specified two or more
                  times:
                    ${concatStringsSep "\n      " offenders}
            '';
        }
        {
          assertion = duplicates (catAttrs "dirPath" allSystemDirectories) == [ ];
          message =
            let
              offenders = duplicates (catAttrs "dirPath" allSystemDirectories);
            in
            ''
              environment.persistence:
                  The following directories were specified two or more
                  times:
                    ${concatStringsSep "\n      " offenders}
            '';
        }
      ];

    warnings =
      let
        usersWithoutUid = attrNames (filterAttrs (n: u: u.uid == null) config.users.users);
        groupsWithoutGid = attrNames (filterAttrs (n: g: g.gid == null) config.users.groups);
        varLibNixosPersistent =
          let
            varDirs = parentsOf "/var/lib/nixos" ++ [ "/var/lib/nixos" ];
            persistedDirs = catAttrs "dirPath" allSystemDirectories;
            mountedDirs = catAttrs "mountPoint" (attrValues allFileSystems);
            persistedVarDirs = intersectLists varDirs persistedDirs;
            mountedVarDirs = intersectLists varDirs mountedDirs;
          in
          persistedVarDirs != [ ] || mountedVarDirs != [ ];
      in
      mkIf (any id allPersistentStoragePaths.enableWarnings)
        (mkMerge [
          (mkIf (!varLibNixosPersistent && (usersWithoutUid != [ ] || groupsWithoutGid != [ ])) [
            ''
              environment.persistence:
                  Neither /var/lib/nixos nor any of its parents are
                  persisted. This means all users/groups without
                  specified uids/gids will have them reassigned on
                  reboot.
                  ${optionalString (usersWithoutUid != [ ]) ''
                  The following users are missing a uid:
                        ${concatStringsSep "\n      " usersWithoutUid}
                  ''}
                  ${optionalString (groupsWithoutGid != [ ]) ''
                  The following groups are missing a gid:
                        ${concatStringsSep "\n      " groupsWithoutGid}
                  ''}
            ''
          ])
        ]);
  }]);

}
