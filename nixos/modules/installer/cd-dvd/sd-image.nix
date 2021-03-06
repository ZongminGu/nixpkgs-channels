# This module creates a bootable SD card image containing the given NixOS
# configuration. The generated image is MBR partitioned, with a FAT /boot
# partition, and ext4 root partition. The generated image is sized to fit
# its contents, and a boot script automatically resizes the root partition
# to fit the device on the first boot.
#
# The derivation for the SD image will be placed in
# config.system.build.sdImage

{ config, lib, pkgs, ... }:

with lib;

let
  rootfsImage = pkgs.callPackage ../../../lib/make-ext4-fs.nix ({
    inherit (config.sdImage) storePaths;
    volumeLabel = "NIXOS_SD";
  } // optionalAttrs (config.sdImage.rootPartitionUUID != null) {
    uuid = config.sdImage.rootPartitionUUID;
  });
in
{
  options.sdImage = {
    imageName = mkOption {
      default = "${config.sdImage.imageBaseName}-${config.system.nixos.label}-${pkgs.stdenv.hostPlatform.system}.img";
      description = ''
        Name of the generated image file.
      '';
    };

    imageBaseName = mkOption {
      default = "nixos-sd-image";
      description = ''
        Prefix of the name of the generated image file.
      '';
    };

    storePaths = mkOption {
      type = with types; listOf package;
      example = literalExample "[ pkgs.stdenv ]";
      description = ''
        Derivations to be included in the Nix store in the generated SD image.
      '';
    };

    bootPartitionID = mkOption {
      type = types.string;
      default = "0x2178694e";
      description = ''
        Volume ID for the /boot partition on the SD card. This value must be a
        32-bit hexadecimal number.
      '';
    };

    rootPartitionUUID = mkOption {
      type = types.nullOr types.string;
      default = null;
      example = "14e19a7b-0ae0-484d-9d54-43bd6fdc20c7";
      description = ''
        UUID for the main NixOS partition on the SD card.
      '';
    };

    bootSize = mkOption {
      type = types.int;
      default = 120;
      description = ''
        Size of the /boot partition, in megabytes.
      '';
    };

    populateBootCommands = mkOption {
      example = literalExample "'' cp \${pkgs.myBootLoader}/u-boot.bin boot/ ''";
      description = ''
        Shell commands to populate the ./boot directory.
        All files in that directory are copied to the
        /boot partition on the SD image.
      '';
    };
  };

  config = {
    fileSystems = {
      "/boot" = {
        device = "/dev/disk/by-label/NIXOS_BOOT";
        fsType = "vfat";
      };
      "/" = {
        device = "/dev/disk/by-label/NIXOS_SD";
        fsType = "ext4";
      };
    };

    sdImage.storePaths = [ config.system.build.toplevel ];

    system.build.sdImage = pkgs.callPackage ({ stdenv, dosfstools, e2fsprogs, mtools, libfaketime, utillinux }: stdenv.mkDerivation {
      name = config.sdImage.imageName;

      nativeBuildInputs = [ dosfstools e2fsprogs mtools libfaketime utillinux ];

      buildCommand = ''
        mkdir -p $out/nix-support $out/sd-image
        export img=$out/sd-image/${config.sdImage.imageName}

        echo "${pkgs.stdenv.buildPlatform.system}" > $out/nix-support/system
        echo "file sd-image $img" >> $out/nix-support/hydra-build-products

        # Create the image file sized to fit /boot and /, plus 20M of slack
        rootSizeBlocks=$(du -B 512 --apparent-size ${rootfsImage} | awk '{ print $1 }')
        bootSizeBlocks=$((${toString config.sdImage.bootSize} * 1024 * 1024 / 512))
        imageSize=$((rootSizeBlocks * 512 + bootSizeBlocks * 512 + 20 * 1024 * 1024))
        truncate -s $imageSize $img

        # type=b is 'W95 FAT32', type=83 is 'Linux'.
        sfdisk $img <<EOF
            label: dos
            label-id: ${config.sdImage.bootPartitionID}

            start=8M, size=$bootSizeBlocks, type=b, bootable
            start=${toString (8 + config.sdImage.bootSize)}M, type=83
        EOF

        # Copy the rootfs into the SD image
        eval $(partx $img -o START,SECTORS --nr 2 --pairs)
        dd conv=notrunc if=${rootfsImage} of=$img seek=$START count=$SECTORS

        # Create a FAT32 /boot partition of suitable size into bootpart.img
        eval $(partx $img -o START,SECTORS --nr 1 --pairs)
        truncate -s $((SECTORS * 512)) bootpart.img
        faketime "1970-01-01 00:00:00" mkfs.vfat -i ${config.sdImage.bootPartitionID} -n NIXOS_BOOT bootpart.img

        # Populate the files intended for /boot
        mkdir boot
        ${config.sdImage.populateBootCommands}

        # Copy the populated /boot into the SD image
        (cd boot; mcopy -psvm -i ../bootpart.img ./* ::)
        # Verify the FAT partition before copying it.
        fsck.vfat -vn bootpart.img
        dd conv=notrunc if=bootpart.img of=$img seek=$START count=$SECTORS
      '';
    }) {};

    boot.postBootCommands = ''
      # On the first boot do some maintenance tasks
      if [ -f /nix-path-registration ]; then
        # Figure out device names for the boot device and root filesystem.
        rootPart=$(readlink -f /dev/disk/by-label/NIXOS_SD)
        bootDevice=$(lsblk -npo PKNAME $rootPart)

        # Resize the root partition and the filesystem to fit the disk
        echo ",+," | sfdisk -N2 --no-reread $bootDevice
        ${pkgs.parted}/bin/partprobe
        ${pkgs.e2fsprogs}/bin/resize2fs $rootPart

        # Register the contents of the initial Nix store
        ${config.nix.package.out}/bin/nix-store --load-db < /nix-path-registration

        # nixos-rebuild also requires a "system" profile and an /etc/NIXOS tag.
        touch /etc/NIXOS
        ${config.nix.package.out}/bin/nix-env -p /nix/var/nix/profiles/system --set /run/current-system

        # Prevents this from running on later boots.
        rm -f /nix-path-registration
      fi
    '';
  };
}
