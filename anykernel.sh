# AnyKernel3 Ramdisk Mod Script
# osm0sis @ xda-developers
# Customized for Xiaomi 11 Lite NE 5G (lisa)

## AnyKernel setup
# begin properties
properties() { '
kernel.string=SukiSU-Ultra Kernel for Xiaomi 11 Lite NE 5G (lisa)
do.devicecheck=1
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
device.name1=lisa
device.name2=lisain
device.name3=lisalite
supported.versions=11-15
supported.patchlevels=
'; } # end properties

# shell variables
block=/dev/block/bootdevice/by-name/boot;
is_slot_device=1;
ramdisk_compression=auto;
patch_vbmeta_flag=auto;

## AnyKernel methods (DO NOT CHANGE)
# import patching functions/variables - see tools/ak3-core.sh
. tools/ak3-core.sh;

## AnyKernel file attributes
# set permissions/ownership for included ramdisk files
set_perm_recursive 0 0 755 644 $ramdisk/*;

## AnyKernel install
dump_boot;

# Install kernel image
write_boot;
## end install
