# aries initramfs / boot.img

小米 2（`aries`，APQ8064）跑主线 Linux 内核用的 initramfs 与可引导 `boot.img` 构建仓库。

```
bootloader -> lk2nd -> boot.img (zImage-dtb + initramfs)
                        -> /init (Rust, musl 静态)
                           -> 挂 /dev/mmcblk0p23 到 /newroot
                           -> /newroot/rootfs 里 exec /sbin/init
```

initramfs 里只有两样东西：静态链接的 Rust `/init` 和设备的 `/lib/firmware`。

## 目录

```
Makefile                   全部构建规则（all / init / initramfs / boot.img / verify / clean）
init/                      Rust /init：无第三方依赖，rust-lld 交叉链接，不需要交叉 gcc
firmware/                  固件，就是 initramfs 里的 /lib/firmware（随仓库分发）
scripts/pack-bootimg.sh    地址布局校验 + 打包；头部注释是各项约束的推导
scripts/mkbootimg.py       打包器
zImage-dtb                 输入：内核 zImage 拼上 aries DTB（git 忽略）
root/                      构建产物：initramfs 暂存树（git 忽略）
boot.img, initramfs.cpio.* 产物（git 忽略）
```

## 依赖

```sh
sudo apt install cpio lz4 python3
rustup toolchain install stable --profile minimal --target armv7-unknown-linux-musleabihf
```

`init/.cargo/config.toml` 用 rustup 自带的 `rust-lld` 链接，libc/crt 取 target 的
`self-contained` 目录，所以整条链路上不需要 ARM 交叉工具链。

## 快速开始

```sh
# 1. 拼出 zImage-dtb（内核树路径按自己的改），放到本目录（与 Makefile 同级）
KERNEL=~/linux
cat $KERNEL/arch/arm/boot/zImage \
    $KERNEL/arch/arm/boot/dts/qcom/qcom-apq8064-xiaomi-aries.dtb > zImage-dtb

# 2. 构建
make                    # -> initramfs.cpio.lz4 + boot.img
make verify             # 只校验现有产物（内核 magic、地址布局、cmdline、initramfs 格式）
fastboot boot boot.img  # 先试跑，不刷机
```

`zImage-dtb`（放在本目录、与 Makefile 同级）和 `firmware/` 是输入文件，本仓库不生成它们；
其余全部由 `make` 产出。
构建可复现（cpio 归一化时间戳 + `--reproducible` + `install -C`）：内容没变，
`boot.img` 逐字节相同，可以直接用 sha256 判断某次改动有没有进 ramdisk。

常用覆盖：

```sh
make COMPRESS=gzip                            # 比 lz4 小约 0.6 MiB，解压慢
make CMDLINE='console=tty0 ignore_loglevel'   # 临时改 cmdline
make BOOTIMG=/tmp/boot.img                    # 产物换个地方
```

## init 做什么

`init/src/main.rs`，全部逻辑就一个文件：

1. 挂 `devtmpfs` / `proc` / `sysfs`，打开 `/dev/kmsg`（日志同时进 console、dmesg 和内存缓冲）。
2. 点亮背光（LM3530 默认 0，屏是黑的；发行版接管之前先用 127 凑合）。
3. 等 `/dev/mmcblk0p23` 出现（最多 15 s），挂到 `/newroot`。
4. 在 `/newroot/rootfs` 下找第一个可执行的 init：
   `sbin/init` → `init` → `usr/sbin/init` → `bin/init` → `usr/bin/init`。
5. 把 initramfs 里的 `/lib/firmware` 整棵拷到 `/newroot/rootfs/lib/firmware`。
   **必须拷**：initramfs 是 tmpfs，switch_root 之后就没了，而内核只会在还能看到 initramfs
   的时候去请求固件。拷完在目标目录留一个指纹文件 `.aries-firmware-stamp`（内容是
   `build.rs` 编译时对 `firmware/` 算的 FNV-1a）；下次开机指纹一致就整棵跳过，省掉每次
   ~8 MiB 的回读。指纹不一致（换了 initramfs 或首次开机）才逐文件比对内容，
   一样的文件不重写。
6. 在发行版根里预挂 `dev` `dev/pts` `proc` `sys` `tmp` `run`。
7. 切根：把 `rootfs` bind 到自己身上（`pivot_root` 只接受挂载点），`pivot_root` 进去，
   再 `MNT_DETACH` 掉旧根释放 initramfs 占的页；失败才回退 `MS_MOVE` + `chroot`。
   最后 `exec /sbin/init`。

**失败处理**：不救援、不开 shell。把自身日志 + 内核 ring buffer 写到 userdata
（`<userdata>/initramfs-boot.log`，有 `/var/log` 时也写一份），`sync`，屏幕上打提示并
等待 `SHUTDOWN_DELAY` 秒（默认 15，`make SHUTDOWN_DELAY=0` 改为立即关机），然后
`reboot(LINUX_REBOOT_CMD_POWER_OFF)`。panic 走同一条路。

## 发行版放在哪

`userdata`（`/dev/mmcblk0p23`）根目录下的 `rootfs/`：

```
/dev/mmcblk0p23
└── rootfs/            <- init 会切到这里
    ├── sbin/init
    ├── lib/firmware/  <- init 把 initramfs 里的固件拷过来
    │   └── .aries-firmware-stamp   <- 指纹一致时整棵跳过
    └── ...
```

实测的 rootfs 以 Alpine minirootfs（`alpine-minirootfs-*-armv7.tar.gz`）为底座解到
`rootfs/`，init 的候补顺序第一个 `/sbin/init` 就能命中。它不带这些固件，所以第 5 步的
拷贝不会被发行版的文件顶掉——这也是指纹方案能成立的前提（换成一个自带
`lib/firmware` 的发行版就得把指纹校验去掉）。