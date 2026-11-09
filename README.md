# session-lock

A Hermes desktop plugin that lists and clears active-session leases.

Hermes lets one process own a conversation at a time. The ownership record lives in
`runtime/active_sessions.json`, and when the owner goes away without releasing it (a closed laptop,
a backend that restarted, a client killed mid-turn) every other client is refused with
"This chat is open somewhere else". Nothing in the app can clear that record.

This plugin puts a chip in the status bar, shows the records, and lets you delete them.

## Install

Windows:

    install\install.bat

Then press `Ctrl+K` in the app and run **Reload desktop plugins**. A plugin that failed its first
load is not picked up again by the folder watcher, so that step is required.

Other systems, by hand:

    <hermes home>/plugins/session-lock/dashboard/{manifest.json,plugin_api.py}
    <hermes home>/desktop-plugins/session-lock/plugin.js

    hermes config set plugins.enabled '["session-lock"]'

`install\uninstall.bat` removes the two plugin folders. Session data is not touched.

## Using it

The chip counts the leases. Clicking it lists them: session id, which surface opened it (`desktop`,
`remote`, ...), pid, how long ago it was updated, and whether the owner process is still alive.

- **Release** removes one record.
- **Clear dead only** removes records whose process is gone or whose process start time no longer
  matches. This is the safe one and needs no confirmation.
- **Release this chat** and **Release all** can remove a record whose owner is still running. Two
  clients can then write to the same conversation, so both ask first and name the pid involved.

Chinese and English strings ship with the plugin. The app picks one from `display.language`, which
defaults to the OS language.

## What it changes on disk

The backend takes `runtime/active_sessions.lock` (the same lock the runtime uses) before reading or
writing the registry, copies the file to `runtime/session-lock-backups/` first (last 30 kept), and
appends one line to `runtime/session-lock-audit.log` per release. Entries go back through the
runtime's own serializer. A registry that does not parse is reported as `409` and left alone rather
than replaced with an empty one.

Releasing a record does not stop anything that is running. It removes the fence and nothing else.

## Layout

    dashboard/    FastAPI router, mounted at /api/plugins/session-lock/
    desktop/      one ES module, loaded by the desktop app
    install/      Windows install and uninstall scripts
    tests/        backend logic tests, no server needed

## Tests

    <hermes home>/.venv/Scripts/python.exe tests/test_release.py

Runs against a temporary `HERMES_HOME` and covers live, dead and pid-reused owners, the confirmation
gate, backups, the audit log, and a corrupt registry.

## Limits

The backend half has to be on the machine whose registry you want to change, since that is where the
file lives. The UI half can be anywhere: it calls whichever backend the app is connected to. With a
remote backend the chip acts on the remote machine, not on the one you are typing on.

Tested on Hermes Agent v0.22.5, Windows 11. Older builds without the dashboard plugin mount will show
the chip and report the backend as unavailable.

MIT.
