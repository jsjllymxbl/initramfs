// SPDX-License-Identifier: GPL-2.0
//
// Lines go to /dev/kmsg (the kernel echoes them to all consoles with
// timestamps) and to an in-memory ring buffer flushed to userdata on boot
// failure.  stdout is only used until kmsg is attached, else every line
// would show up twice.

use std::fs::File;
use std::io::Write;
use std::sync::atomic::Ordering;
use std::sync::{Mutex, MutexGuard};

const MAX_LOG: usize = 256 * 1024;

/// Also used by the shutdown countdown, which redraws its line on the console.
pub const PREFIX: &str = "RINIT";

static BUFFER: Mutex<Vec<u8>> = Mutex::new(Vec::new());
static KMSG: Mutex<Option<File>> = Mutex::new(None);

/// Hand over the /dev/kmsg writer once devtmpfs is up.
pub fn attach_kmsg(file: Option<File>) {
    if let Ok(mut slot) = KMSG.lock() {
        *slot = file;
    }
}

/// Never block on the failure path: the panic hook can be re-entered while
/// the panicking thread still holds a lock, which would deadlock PID 1.
fn lock_on<'a, T>(m: &'a Mutex<T>, may_block: bool) -> Option<MutexGuard<'a, T>> {
    if may_block {
        m.lock().ok()
    } else {
        m.try_lock().ok()
    }
}

pub fn line(args: std::fmt::Arguments) {
    let msg = format!("{PREFIX}: {args}\n");
    let raw = msg.as_bytes();

    let may_block = !crate::IN_FATAL.load(Ordering::Relaxed);

    if let Some(mut slot) = lock_on(&KMSG, may_block) {
        match slot.as_mut() {
            // The kernel fans kmsg records out to all consoles itself.
            Some(kmsg) => {
                if kmsg.write_all(raw).and_then(|_| kmsg.flush()).is_err() {
                    let mut stdout = std::io::stdout();
                    let _ = stdout.write_all(raw);
                    let _ = stdout.flush();
                }
            }
            None => {
                let mut stdout = std::io::stdout();
                let _ = stdout.write_all(raw);
                let _ = stdout.flush();
            }
        }
    }

    if let Some(mut buffer) = lock_on(&BUFFER, may_block) {
        if buffer.len() < MAX_LOG {
            buffer.extend_from_slice(raw);
        }
    }
}

/// Copy of everything this program logged so far.
pub fn snapshot() -> Vec<u8> {
    BUFFER.lock().map(|b| b.clone()).unwrap_or_default()
}
