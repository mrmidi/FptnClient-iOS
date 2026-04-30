"""LLDB helpers for FptnVPN tunnel/provider memory debugging.

Load from LLDB with:

    command script import /Users/mrmidi/DEV/FptnClient-iOS/scripts/debug/fptn_lldb.py

Then use:

    fptn_breaks
    fptn_dump
    fptn_stop_hooks
"""

import lldb


def _run(debugger, result, command):
    result.PutCString("\n===== " + command + " =====")
    debugger.HandleCommand(command)


def fptn_dump(debugger, command, result, internal_dict):
    """Dump high-signal state for provider death and memory pressure stops."""
    commands = [
        "thread list",
        "thread backtrace all",
        "register read",
        "image lookup -a $pc",
        "memory region --all",
        'image lookup -rn "google::protobuf::MessageLite::ParseFromArray"',
        'image lookup -rn "google::protobuf::internal::MergeFromImpl"',
        'image lookup -rn "websocket_client_bridge"',
        'image lookup -rn "packet_callback_adapter"',
        'image lookup -rn "disconnected_callback_adapter"',
        'image lookup -rn "client_run_thread"',
    ]

    for item in commands:
        _run(debugger, result, item)


def fptn_breaks(debugger, command, result, internal_dict):
    """Install useful fatal/native boundary breakpoints for tunnel debugging."""
    commands = [
        "breakpoint set -n std::terminate",
        "breakpoint set -n abort",
        "breakpoint set -n __cxa_throw",
        "breakpoint set -n objc_exception_throw",
        "breakpoint set -n websocket_client_bridge_stop",
        "breakpoint set -n websocket_client_bridge_destroy",
        "breakpoint set -n disconnected_callback_adapter",
        "breakpoint set -n packet_callback_adapter",
        "breakpoint set -n client_run_thread",
        "process handle SIGPIPE -n true -p true -s false",
        "process handle SIGABRT -n true -p true -s true",
        "process handle SIGSEGV -n true -p true -s true",
        "process handle SIGBUS -n true -p true -s true",
        "process handle SIGSTOP -n true -p true -s true",
    ]

    for item in commands:
        result.PutCString(item)
        debugger.HandleCommand(item)


def fptn_proto_sample(debugger, command, result, internal_dict):
    """Set a sampled protobuf parse breakpoint.

    Usage:

        fptn_proto_sample
        fptn_proto_sample 10000
    """
    ignore_count = command.strip() or "10000"
    debugger.HandleCommand(
        'breakpoint set -n google::protobuf::MessageLite::ParseFromArray'
    )
    target = debugger.GetSelectedTarget()
    breakpoint = target.GetBreakpointAtIndex(target.GetNumBreakpoints() - 1)
    if breakpoint and breakpoint.IsValid():
        breakpoint.SetIgnoreCount(int(ignore_count))
        result.PutCString(
            "Installed sampled ParseFromArray breakpoint with ignore-count "
            + ignore_count
        )
    else:
        result.PutCString("Failed to install ParseFromArray breakpoint")


def fptn_stop_hooks(debugger, command, result, internal_dict):
    """Install a global stop hook that runs fptn_dump.

    This is noisy. Prefer fptn_dump manually unless you are chasing a rare stop.
    """
    debugger.HandleCommand('target stop-hook add -o "fptn_dump"')
    result.PutCString("Installed stop hook: fptn_dump")


def __lldb_init_module(debugger, internal_dict):
    debugger.HandleCommand("command script add -f fptn_lldb.fptn_dump fptn_dump")
    debugger.HandleCommand("command script add -f fptn_lldb.fptn_breaks fptn_breaks")
    debugger.HandleCommand(
        "command script add -f fptn_lldb.fptn_proto_sample fptn_proto_sample"
    )
    debugger.HandleCommand(
        "command script add -f fptn_lldb.fptn_stop_hooks fptn_stop_hooks"
    )
    debugger.HandleCommand("settings set stop-disassembly-display never")
    debugger.HandleCommand(
        'settings set target.process.thread.step-avoid-regexp '
        '"^(libsystem|CoreFoundation|Foundation|NetworkExtension|libc\\+\\+|libc\\+\\+abi)"'
    )
    print(
        "FPTN LLDB helpers loaded: "
        "fptn_breaks, fptn_dump, fptn_proto_sample, fptn_stop_hooks"
    )
