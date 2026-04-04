# TBDDaemon

After changing daemon or shared code (`Sources/TBDDaemon/`, `Sources/TBDShared/`), always use `scripts/restart.sh` (full restart), NOT `scripts/restart.sh --app`.

The app-only restart leaves the daemon running the old binary. New RPC fields will silently decode as nil, causing features to appear broken while the code is correct.
