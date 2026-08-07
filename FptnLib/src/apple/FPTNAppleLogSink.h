/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

#pragma once

#ifdef __cplusplus
extern "C" {
#endif

/// Routes every native (spdlog) log line into the unified system log, so the
/// C++ tunnel is visible in Console.app and Xcode instead of writing to a
/// stdout nobody reads. Idempotent and thread-safe; call it before starting
/// anything native.
///
/// Everything lands under subsystem `org.fptn`, with the spdlog logger name as
/// the category. To watch a live tunnel:
///
///     log stream --predicate 'subsystem == "org.fptn"' --level debug
///
/// or paste `subsystem:org.fptn` into Console.app's search field. Console hides
/// info/debug by default — enable Action > Include Info/Debug Messages.
///
/// Note messages are logged `%{public}`: this is a VPN, so the redactor in
/// FPTNAppleLogSink.mm strips addresses and tokens before they reach the log
/// rather than relying on the private-data setting.
void FPTNInstallAppleLogSink(void);

/// Sets the native log level: "warning", "info", "debug", or "trace".
/// Unknown values are ignored. Safe to call at any time.
void FPTNSetAppleLogLevel(const char *level);

#ifdef __cplusplus
}
#endif
