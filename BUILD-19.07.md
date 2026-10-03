# Building this 19.07 fork

OpenWrt 19.07 is end of life. This fork keeps it buildable for old 4/32 MB
devices (TL-WR740N, TL-WR741ND, TL-WR841N, RB433) with a few backports:
kernel 4.14.336, WireGuard (`wireguard-linux-compat` 1.0.20220627),
vxlan, newer odhcpd and cmake.

Feeds (see `feeds.conf.default`):

| Feed | Repository | Branch |
|---|---|---|
| packages | https://github.com/kofec/packages_1907 | `openwrt-19.07` |
| luci | https://github.com/kofec/luci_1907 | `openwrt-19.07` |
| routing | https://git.openwrt.org/feed/routing.git | `openwrt-19.07` |

## Build environment

19.07 expects a host toolchain of its era (gcc 7-9, python2), which
current distributions no longer ship, so the build runs in an Alpine 3.12
container described by [Containerfile-alpine](Containerfile-alpine).
The container user `kofec` is created with `adduser -D`, which gives
uid 1000 - the same uid as the first user on a typical Ubuntu host, so
the mounted tree stays writable. Adjust the user name if yours is
different.

```sh
docker build -t openwrt:alpine -f Containerfile-alpine .
```

## Build

```sh
git clone https://github.com/kofec/openwrt_1907.git
cd openwrt_1907
./scripts/feeds update -a
./scripts/feeds install -a

docker run --interactive --rm --tty --ulimit 'nofile=1024:262144' \
  --volume "$(pwd):/workdir" --workdir '/workdir' openwrt:alpine /bin/bash

# inside the container
cp diffconfig_wr741ndv1_1907 .config
make defconfig
make download
make -j"$(nproc)"
```

Images land in `bin/targets/<board>/<subtarget>/`, e.g.
`bin/targets/ath79/tiny/openwrt-ath79-tiny-tplink_tl-wr741-v1-squashfs-sysupgrade.bin`.

Non-interactive variant:

```sh
docker run --rm --ulimit 'nofile=1024:262144' -v "$(pwd):/workdir" -w /workdir \
  openwrt:alpine sh -c 'make defconfig && make -j"$(nproc)"'
```

Always start from a diffconfig (`cp diffconfig_... .config`), not from an
old full `.config`: packages that were only pulled in as dependencies stay
selected in a full `.config` even after nothing needs them any more.

## Profiles: one per model, 4 MB flash / 32 MB RAM

All `ath79/tiny` TP-Link boards share one package profile; the diffconfigs
differ only in the device line (and the `_bonding` / `_vxlan` extras).

- LuCI with statistics (collectd + rrdtool) and watchcat
- WireGuard (`kmod-wireguard`, `wireguard-tools`, `luci-proto-wireguard`)
- relayd, odhcpd as DHCP server, travelmate with its LuCI app
- Wake-on-LAN (`etherwake`, `luci-app-wol`)
- with [files-service-ap](#service-ap-fallback-files-service-ap) copied to
  `files/`: service AP fallback
- no IPv6, no firewall/iptables, no dnsmasq, no ppp, no opkg
- default lan address 192.168.2.1 (also failsafe), only after first boot
  or factory reset - see below

| diffconfig | Device | SoC | Overlay |
|---|---|---|---|
| [diffconfig_wr741ndv1_1907](diffconfig_wr741ndv1_1907) | TL-WR741ND v1 | ar7240 | 384 KiB |
| [diffconfig_wr740nv1v2_1907](diffconfig_wr740nv1v2_1907) | TL-WR740N v1/v2 | ar7240 | 384 KiB |
| [diffconfig_wr741ndv4_1907](diffconfig_wr741ndv4_1907) | TL-WR741ND v4 | ar9331 | 384 KiB |
| [diffconfig_wr740nv4_1907](diffconfig_wr740nv4_1907) | TL-WR740N v4 | ar9331 | 384 KiB |
| [diffconfig_wr841nv9_1907](diffconfig_wr841nv9_1907) | TL-WR841N v9 | qca9533 | 384 KiB |
| [diffconfig_wr841nv11_1907](diffconfig_wr841nv11_1907) | TL-WR841N v11 | qca9533 | 384 KiB |
| [diffconfig_wr741ndv1_1907_vxlan](diffconfig_wr741ndv1_1907_vxlan) | TL-WR741ND v1 + vxlan | ar7240 | 384 KiB |
| [diffconfig_wr740nv1v2_1907_vxlan](diffconfig_wr740nv1v2_1907_vxlan) | TL-WR740N v1/v2 + vxlan | ar7240 | 384 KiB |
| [diffconfig_wr741ndv1_1907_bonding](diffconfig_wr741ndv1_1907_bonding) | TL-WR741ND v1 + bonding | ar7240 | 320 KiB |
| [diffconfig_wr740nv1v2_1907_bonding](diffconfig_wr740nv1v2_1907_bonding) | TL-WR740N v1/v2 + bonding | ar7240 | 320 KiB |
| [diffconfig_wr741ndv4_1907_bonding](diffconfig_wr741ndv4_1907_bonding) | TL-WR741ND v4 + bonding | ar9331 | 320 KiB |

Space saving tricks used there:
- `# CONFIG_IPV6 is not set`, `# CONFIG_KERNEL_IPV6 is not set`
- `CONFIG_STRIP_KERNEL_EXPORTS=y`
- `# CONFIG_PACKAGE_uboot-envtools is not set` - TP-Link boards have no
  U-Boot environment partition
- `# CONFIG_SIGNED_PACKAGES is not set` - drops `usign` and
  `openwrt-keyring`, useless without opkg
- collectd in the packages fork no longer depends on `libip4tc` and
  `libltdl`; nothing links them, and `libip4tc2` + `libxtables12` alone
  were ~88 KB of compressed squashfs

Result on TL-WR741ND v1: squashfs 2.40 MB -> 2.29 MB, overlay 320 KiB ->
448 KiB, with travelmate and the service AP script included.
`luci-app-travelmate` adds ~47 KB (in 19.07 it is still Lua/CBI and needs
`luci-compat`), which costs one erase block: 384 KiB. The JavaScript
version from 21.02+ does not need `luci-compat`, but it only works with
travelmate 2.x, which depends on `curl` and `ca-bundle` - more than the
Lua app saves. Bonding costs another block (320 KiB).

### How much flash is left

On 4 MB TP-Link devices the firmware partition is 3904 KiB (3997696 B).
The image is header + kernel + squashfs (right after the kernel, not
block aligned), padded to a 64 KiB erase block and terminated with the
`deadc0de` JFFS2 marker; everything from that marker on becomes the
overlay (`rootfs_data`) for configuration. With JFFS2 reserving blocks for
garbage collection, an overlay of 256 KiB is practically full right after
first boot; aim for 320 KiB or more.

Check after a build, straight from the image:

```sh
python3 - bin/targets/ath79/tiny/*tl-wr741-v1-squashfs-sysupgrade.bin <<'PY'
import struct, sys
b = open(sys.argv[1], 'rb').read()
sq = b.find(b'hsqs'); end = sq + struct.unpack('<Q', b[sq+40:sq+48])[0]
dc = b.rfind(b'\xde\xad\xc0\xde')
print(f"overlay: {(3997696 - dc) // 1024} KiB, free before next block: {dc - end} B")
PY
```

## Default LAN address

`config_generate` hardcodes 192.168.1.1. This tree carries the upstream
option from 23.05 (`baf76634f3`): Image configuration -> Use preinit IP
configuration as default LAN IP. It generates `/etc/board.d/99-lan-ip`,
which puts the preinit address into `board.json`; `config_generate` uses
it only when `/etc/config/network` does not exist, i.e. on first boot and
after factory reset. Settings kept across sysupgrade are untouched.

```
CONFIG_IMAGEOPT=y
CONFIG_PREINITOPT=y
CONFIG_TARGET_PREINIT_IP="192.168.2.1"
CONFIG_TARGET_PREINIT_BROADCAST="192.168.2.255"
CONFIG_TARGET_DEFAULT_LAN_IP_FROM_PREINIT=y
```

The 19.07 `board_detect` only runs executable board.d scripts, so the
generated file gets `chmod 0755` here (upstream checks `-s` instead).
odhcpd serves DHCP on any static lan address (pool .100-.249).

## Service AP fallback (files-service-ap)

A router that reaches the internet as a wifi client (STA, e.g. with
travelmate or relayd) is unreachable once that network is gone or its
password changes. [files-service-ap](files-service-ap) adds a small procd
service that opens a service AP in that case:

1. Every 10 s it pings the default gateway (only when a wifi STA interface
   is configured at all).
2. After `timeout` seconds (default 180) without a working uplink it stops
   travelmate, disables all enabled STA interfaces and enables the
   `wireless.service` AP on `lan`. The STA must go: an AP on the same radio
   as an unconnected STA does not come up.
3. odhcpd serves DHCP on `lan` (default for a static lan when dnsmasq is
   not installed: `dhcp.odhcpd.maindhcp=1`, `dhcp.lan.dhcpv4=server`), so a
   laptop or phone gets an address and can open LuCI / ssh on the lan IP.
4. After `service_time` seconds (default 600) the AP goes off whether or
   not anyone is connected, the STA interfaces are restored and travelmate
   started again (if enabled). With no uplink the cycle repeats: 3 minutes
   searching, 10 minutes service AP.

The disabled STA list is kept in `/etc/service_ap.sta`, so a reboot in
service mode restores the clients first.

To use it:

```sh
cp -r files-service-ap files
vi files/etc/config/service_ap     # set ssid and key
chmod 600 files/etc/config/service_ap
```

`/files` is in `.gitignore`, so the key stays out of git. With an empty
`key` the service AP is open.

The init script is enabled automatically at image build time
(`/etc/rc.d/S99service_ap`). Logs: `logread -e service_ap`.
