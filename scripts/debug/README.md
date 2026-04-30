# FptnVPN Debug Scripts

## LLDB provider helpers

Load the helper after attaching LLDB to `FptnVPNTunnel`:

```lldb
command script import /Users/mrmidi/DEV/FptnClient-iOS/scripts/debug/fptn_lldb.py
```

Common commands:

```lldb
fptn_breaks
fptn_dump
fptn_proto_sample 10000
```

`fptn_stop_hooks` installs a global stop hook that runs `fptn_dump` on every stop.
It is useful for rare failures but noisy during normal stepping.
