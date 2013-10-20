#!/bin/bash
#
# requires:
#  bash
#
set -e
set -x

# variables

declare src_filepath=$1
declare dst_filename=zxcv.raw

# validate

[[ $UID == 0 ]] || { echo "Must run as root." >&2; exit 1; }
[[ -f "${src_filepath}" ]] || { echo "file not found: ${src_filepath}" >&2; exit 1; }
size=$(stat -c %s ${src_filepath})

# main

## disk

truncate -s ${size} ${dst_filename}

## mbr

lodev=$(losetup -f)
losetup ${lodev} ${dst_filename}
dd if=${src_filepath} of=${lodev} bs=512 count=1
udevadm settle
losetup -d ${lodev}

## partition

# $ sudo parted centos-6.4_x86_64.raw print | sed "1,/^Number/d" | egrep -v '^$'
#  1      32.3kB  4294MB  4294MB  primary  ext4
#  2      4295MB  5368MB  1073MB  primary  linux-swap(v1)
function lspart() {
  local filepath=$1
  parted ${filepath} print | sed "1,/^Number/d" | egrep -v '^$' | awk '{print $1, $6}'
}

# $ sudo kpartx -va centos-6.4_x86_64.raw
# add map loop0p1 (253:0): 0 8386498 linear /dev/loop0 63
# add map loop0p2 (253:1): 0 2095104 linear /dev/loop0 8388608
src_lodev=$(kpartx -va ${src_filepath} | egrep "^add map" | awk '{print $3}' | sed 's,[0-9]$,,' | uniq); udevadm settle
dst_lodev=$(kpartx -va ${dst_filename} | egrep "^add map" | awk '{print $3}' | sed 's,[0-9]$,,' | uniq); udevadm settle

while read line; do
  set ${line}
  src_part_filename=/dev/mapper/${src_lodev}${1}
  dst_part_filename=/dev/mapper/${dst_lodev}${1}

  src_disk_uuid=$(blkid -c /dev/null -sUUID -ovalue ${src_part_filename})
  case "${2}" in
  *swap*)
    mkswap -f -L swap -U ${src_disk_uuid} ${dst_part_filename}
    ;;
  ext*|*)
    src_part_label=$(e2label ${src_part_filename})
    [[ -z "${src_part_label}" ]] || tune2fs -L ${src_part_label} ${dst_part_filename}
    mkfs.ext4 -F -E lazy_itable_init=1 -U ${src_disk_uuid} ${dst_part_filename}
    tune2fs -c 0 -i 0 ${dst_part_filename}
    tune2fs -o acl    ${dst_part_filename}

    src_mnt=/tmp/tmp$(date +%s.%N)
    dst_mnt=/tmp/tmp$(date +%s.%N)
    mkdir -p ${src_mnt}
    mkdir -p ${dst_mnt}

    mount ${src_part_filename} ${src_mnt}
    mount ${dst_part_filename} ${dst_mnt}

    rsync -aHA ${src_mnt}/ ${dst_mnt}
    sync

    umount -l ${src_mnt}
    umount -l ${dst_mnt}

    rmdir    ${src_mnt}
    rmdir    ${dst_mnt}
    ;;
  esac
done < <(lspart ${src_filepath})
udevadm settle

## bootloader

rootfs_dev=
while read line; do
  set ${line}
  src_part_filename=/dev/mapper/${src_lodev}${1}
  case "${2}" in
  ext*|*)
    [[ -n "${rootfs_dev}" ]] || rootfs_dev=/dev/mapper/${dst_lodev}${1}
  esac
done < <(lspart ${src_filepath})

chroot_dir=/tmp/tmp$(date +%s.%N)
mkdir -p ${chroot_dir}
mount ${rootfs_dev} ${chroot_dir}
cat ${chroot_dir}/etc/fstab

root_dev="hd0"
tmpdir=/tmp/vmbuilder-grub

new_filename=${tmpdir}/${dst_filename##*/}
mkdir -p ${chroot_dir}/${tmpdir}

touch ${chroot_dir}/${new_filename}
mount --bind ${dst_filename} ${chroot_dir}/${new_filename}

devmapfile=${tmpdir}/device.map
touch ${chroot_dir}/${devmapfile}

disk_id=0
printf "(hd%d) %s\n" ${disk_id} ${new_filename} >>  ${chroot_dir}/${devmapfile}
cat ${chroot_dir}/${devmapfile}

mkdir -p ${chroot_dir}/${tmpdir}

grub_cmd="chroot ${chroot_dir} grub --batch --device-map=${devmapfile}"
cat <<-_EOS_ | ${grub_cmd}
	root (${root_dev},0)
	setup (hd0)
	quit
	_EOS_

umount ${chroot_dir}/${new_filename}
umount ${chroot_dir}
rmdir  ${chroot_dir}

kpartx -vd ${src_filepath}
kpartx -vd ${dst_filename}
