# AnyKernel3 — Xiaomi 11 Lite NE 5G (lisa)
properties() { '
kernel.string=SukiSU-Ultra Kernel for lisa
do.devicecheck=1
do.modules=1
do.systemless=0
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
dump_boot;
write_boot;
