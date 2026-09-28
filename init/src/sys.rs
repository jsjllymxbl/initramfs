// SPDX-License-Identifier: GPL-2.0
//
// Raw armv7 (EABI) syscalls for the calls std does not expose: r7 = syscall
// number, r0..r5 = arguments, result in r0 (negative errno on failure).

use std::ffi::CString;
use std::io;

const SYS_MOUNT: usize = 21;
const SYS_SYNC: usize = 36;
const SYS_PIVOT_ROOT: usize = 218;
const SYS_UMOUNT2: usize = 52;
const SYS_CHROOT: usize = 61;
const SYS_SETHOSTNAME: usize = 74;
const SYS_REBOOT: usize = 88;

// mount(2) flags
pub const MS_NOSUID: usize = 2;
pub const MS_NODEV: usize = 4;
pub const MS_NOEXEC: usize = 8;
pub const MS_NOATIME: usize = 1024;
pub const MS_BIND: usize = 4096;
pub const MS_MOVE: usize = 8192;
pub const MS_REC: usize = 16384;
pub const MS_STRICTATIME: usize = 1 << 24;

// umount2(2) flags
pub const MNT_DETACH: usize = 2;

const LINUX_REBOOT_MAGIC1: usize = 0xfee1dead;
const LINUX_REBOOT_MAGIC2: usize = 672274793;
const LINUX_REBOOT_CMD_POWER_OFF: usize = 0x4321fedc;

#[inline(always)]
unsafe fn syscall(n: usize, a0: usize, a1: usize, a2: usize, a3: usize, a4: usize) -> isize {
    let ret: isize;
    // SAFETY: `svc 0` is the armv7 syscall entry; the kernel preserves the
    // argument registers.  clobber_abi("C") implies a memory clobber, keeping
    // the CString stores from being sunk past the svc.  Omitted here only
    // because the body of an `unsafe fn` already is one.
    core::arch::asm!(
        "svc 0",
        in("r7") n,
        inlateout("r0") a0 => ret,
        in("r1") a1,
        in("r2") a2,
        in("r3") a3,
        in("r4") a4,
        clobber_abi("C"),
    );
    ret
}

fn cvt(ret: isize) -> io::Result<()> {
    if (-4095..0).contains(&ret) {
        Err(io::Error::from_raw_os_error((-ret) as i32))
    } else {
        Ok(())
    }
}

fn cstr(s: &str) -> io::Result<CString> {
    CString::new(s).map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "NUL byte in path"))
}

fn ptr_of(s: &Option<CString>) -> usize {
    s.as_ref().map_or(0, |c| c.as_ptr() as usize)
}

/// mount(2).  `None` means "pass NULL", which is how bind/remount operations
/// spell an absent source, filesystem type or option string.
pub fn mount(
    source: Option<&str>,
    target: &str,
    fstype: Option<&str>,
    flags: usize,
    data: Option<&str>,
) -> io::Result<()> {
    let source = source.map(cstr).transpose()?;
    let fstype = fstype.map(cstr).transpose()?;
    let data = data.map(cstr).transpose()?;
    let target = cstr(target)?;

    let ret = unsafe {
        syscall(
            SYS_MOUNT,
            ptr_of(&source),
            target.as_ptr() as usize,
            ptr_of(&fstype),
            flags,
            ptr_of(&data),
        )
    };
    cvt(ret)
}

pub fn umount2(target: &str, flags: usize) -> io::Result<()> {
    let target = cstr(target)?;
    cvt(unsafe { syscall(SYS_UMOUNT2, target.as_ptr() as usize, flags, 0, 0, 0) })
}

pub fn pivot_root(new_root: &str, put_old: &str) -> io::Result<()> {
    let new_root = cstr(new_root)?;
    let put_old = cstr(put_old)?;
    cvt(unsafe {
        syscall(SYS_PIVOT_ROOT, new_root.as_ptr() as usize, put_old.as_ptr() as usize, 0, 0, 0)
    })
}

pub fn chroot(path: &str) -> io::Result<()> {
    let path = cstr(path)?;
    cvt(unsafe { syscall(SYS_CHROOT, path.as_ptr() as usize, 0, 0, 0, 0) })
}

pub fn sethostname(name: &str) -> io::Result<()> {
    let name = cstr(name)?;
    cvt(unsafe { syscall(SYS_SETHOSTNAME, name.as_ptr() as usize, name.as_bytes().len(), 0, 0, 0) })
}

pub fn sync_all() {
    unsafe {
        syscall(SYS_SYNC, 0, 0, 0, 0, 0);
    }
}

/// Power the board off.  Only returns if the syscall failed.
pub fn power_off() -> io::Result<()> {
    cvt(unsafe {
        syscall(
            SYS_REBOOT,
            LINUX_REBOOT_MAGIC1,
            LINUX_REBOOT_MAGIC2,
            LINUX_REBOOT_CMD_POWER_OFF,
            0,
            0,
        )
    })
}
