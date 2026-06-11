# AnyKernel3 — Xiaomi 11 Lite NE 5G (lisa)
properties() { '
kernel.string=SukiSU-Ultra + SUSFS Kernel for lisa
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
'; }
block=/dev/block/bootdevice/by-name/boot;
is_slot_device=1;
ramdisk_compression=auto;
patch_vbmeta_flag=auto;
. tools/ak3-core.sh;
set_perm_recursive 0 0 755 644 $ramdisk/*;
dump_boot;
write_boot;
