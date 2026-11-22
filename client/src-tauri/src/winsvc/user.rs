//! Windows 仅为当前用户安装（安装程序里选"仅为我安装"，不需要管理员权限）。
//!
//! 没有系统服务：被控端和调试构建直接运行时一样，在托盘进程里、以登录的用户的身份运行。所以锁屏、登录界面和
//! UAC 确认框不能控制（它们在安全桌面上，见 `host::desktop`），以管理员身份运行的窗口只能看、不能操作（UIPI），
//! 登录之后 Airhand 才会运行。
//!
//! * 安装包复制完文件后运行 `airhand.exe --install-user`：在 `HKCU\Software\Airhand` 里记下这个 airhand.exe 的位置
//!   （启动时据此认出自己是装好的，见 [`installed_here`]；没有安装的 airhand.exe 不能运行），按 config.toml 设置登录时自动启动；
//! * 登录时自动启动（`config.toml` 的 `autostart`，托盘里可以切换）= `HKCU\...\Run` 里的 `Airhand`；
//! * 升级前（`--quit`）、卸载时（`--uninstall-user`）让托盘退出，否则 airhand.exe 正在使用，无法覆盖、删除：
//!   托盘等着一个命名事件（[`watch_quit`]）；
//! * config.toml 和为所有用户安装时一样在程序旁边：安装目录在用户自己的目录里，托盘直接读写；
//! * 这台电脑同时也为所有用户安装了 Airhand（有系统服务）时，这一份不运行，否则两个被控端同时运行（见 `crate::run`）。

use std::path::Path;
use std::time::Duration;

use anyhow::{Context, Result};
use tracing::{info, warn};
use windows::Win32::Foundation::{CloseHandle, HANDLE, WAIT_OBJECT_0};
use windows::Win32::System::Threading::{
    CreateEventW, EVENT_MODIFY_STATE, INFINITE, OpenEventW, ResetEvent, SetEvent,
    WaitForSingleObject,
};
use windows::core::{HSTRING, w};
use winreg::RegKey;
use winreg::enums::{HKEY_CURRENT_USER, KEY_READ, KEY_SET_VALUE};

use super::{RUN_KEY, SERVICE_NAME};

/// 记下安装位置的注册表项（`HKCU` 下）和值。安装包（`windows/hooks.nsh`）也用到它们。
/// 注册表的键名不分大小写：这个键也是 Tauri 安装包的 `Software\airhand`（它在里面记安装位置和语言），
/// 所以只增删自己的值，不动整个键
const KEY: &str = r"Software\Airhand";
const VALUE: &str = "UserInstall";
/// 让托盘退出的命名事件（每个会话一个，和单实例的互斥体一样，见 `crate::single_instance`）
const QUIT_EVENT: &str = r"Local\Airhand.Quit";

/// 这个 airhand.exe 是不是仅为当前用户安装好的（安装包运行 `--install-user` 时记下了它的位置）。
/// 是的话没有系统服务，被控端在托盘进程里运行
pub fn installed_here() -> bool {
    let recorded = RegKey::predef(HKEY_CURRENT_USER)
        .open_subkey(KEY)
        .and_then(|k| k.get_value::<String, _>(VALUE));
    match (recorded, std::env::current_exe()) {
        (Ok(path), Ok(me)) => super::same_file(Path::new(&path), &me),
        (Err(e), _) if e.kind() == std::io::ErrorKind::NotFound => false,
        (Err(e), _) => {
            warn!("can't read the per-user installation: {e}");
            false
        }
        (_, Err(e)) => {
            warn!("can't find this program's path: {e}");
            false
        }
    }
}

/// `--install-user`：记下安装位置，按 config.toml 设置登录时自动启动。安装包在复制完文件后调用
pub(super) fn install() -> Result<()> {
    let exe = std::env::current_exe()?;
    crate::config::ensure_file().context("can't create config.toml")?;
    let (key, _) = RegKey::predef(HKEY_CURRENT_USER)
        .create_subkey(KEY)
        .context("can't create the registry key")?;
    key.set_value(VALUE, &exe.as_os_str())
        .context("can't record the installation")?;
    let autostart = crate::config::settings().autostart;
    apply_autostart(autostart)?;
    info!(
        "Airhand is installed for this user ({}, autostart {})",
        exe.display(),
        if autostart { "on" } else { "off" }
    );
    Ok(())
}

/// `--uninstall-user`：删除登录时自动启动和记下的安装位置，让托盘退出。安装目录里的文件由卸载程序删除
pub(super) fn uninstall() -> Result<()> {
    apply_autostart(false)?;
    let hkcu = RegKey::predef(HKEY_CURRENT_USER);
    match hkcu
        .open_subkey_with_flags(KEY, KEY_READ | KEY_SET_VALUE)
        .and_then(|key| {
            key.delete_value(VALUE)?;
            Ok(key.enum_keys().next().is_none() && key.enum_values().next().is_none())
        }) {
        // 键里没有别的东西了，也删掉
        Ok(true) => {
            let _ = hkcu.delete_subkey(KEY);
        }
        Ok(false) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(e).context("can't delete the recorded installation"),
    }
    quit()
}

/// `--quit`：让本会话里的托盘退出并等它退出。升级时安装包在复制文件之前调用（运行的是旧版本）
pub(super) fn quit() -> Result<()> {
    unsafe {
        // 打不开：没有托盘在等，也就是没有在运行
        if let Ok(event) = OpenEventW(EVENT_MODIFY_STATE, false, &HSTRING::from(QUIT_EVENT)) {
            let r = SetEvent(event);
            let _ = CloseHandle(event);
            r.context("SetEvent")?;
        }
    }
    super::wait_for_other_instances(Duration::from_secs(8), false);
    Ok(())
}

/// 托盘（被控端在本进程里运行时）：安装包要升级、卸载时（`--quit`、`--uninstall-user`）退出
pub fn watch_quit(on_quit: impl FnOnce() + Send + 'static) {
    let event = match unsafe { CreateEventW(None, false, false, &HSTRING::from(QUIT_EVENT)) } {
        Ok(h) => h,
        Err(e) => {
            warn!("can't create the quit event: {e}");
            return;
        }
    };
    // 不算之前留下的信号（自动复位的事件没人等时信号一直留着）
    let _ = unsafe { ResetEvent(event) };
    // HANDLE 不能跨线程传递，传它的值
    let raw = event.0 as usize;
    std::thread::spawn(move || {
        if unsafe { WaitForSingleObject(HANDLE(raw as _), INFINITE) } == WAIT_OBJECT_0 {
            info!("the installer asked Airhand to quit");
            on_quit();
        }
    });
}

/// 登录时自动启动：本用户的 `HKCU\...\Run` 里的 `Airhand`
pub fn apply_autostart(on: bool) -> Result<()> {
    let hkcu = RegKey::predef(HKEY_CURRENT_USER);
    if on {
        let exe = std::env::current_exe()?;
        let (run, _) = hkcu
            .create_subkey(RUN_KEY)
            .context("can't open the Run key")?;
        run.set_value(SERVICE_NAME, &format!("\"{}\"", exe.display()))
            .context("can't write the Run key")?;
    } else {
        let r = hkcu
            .open_subkey_with_flags(RUN_KEY, KEY_SET_VALUE)
            .and_then(|run| run.delete_value(SERVICE_NAME));
        match r {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            r => r.context("can't delete the Run key")?,
        }
    }
    Ok(())
}

/// 这台电脑还为所有用户安装了 Airhand：告诉用户这一份不再运行
pub fn show_service_installed() {
    use windows::Win32::UI::WindowsAndMessaging::{MB_ICONINFORMATION, MB_OK, MessageBoxW};
    let text = HSTRING::from(tr!(
        "这台电脑已经为所有用户安装了 Airhand（作为系统服务运行），仅为你安装的这一份不再运行，以免两个被控端同时运行。\n\n请打开为所有用户安装的 Airhand；仅为你安装的这一份可以在“设置 → 应用”里卸载。",
        "Airhand is also installed for all users on this computer (as a system service), so the copy installed just for you doesn't run: two hosts would run at the same time.\n\nPlease open the Airhand installed for all users; you can uninstall the copy installed just for you in Settings → Apps."
    ));
    unsafe {
        MessageBoxW(None, &text, w!("Airhand"), MB_OK | MB_ICONINFORMATION);
    }
}
