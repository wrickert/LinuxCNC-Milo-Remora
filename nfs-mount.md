# G-code delivery — read-only NFS from Unraid

FreeCAD does CAM on the desktop and saves into its Nextcloud folder. That syncs to the
server. The mill reads the result straight off the Unraid share.

**No Nextcloud client, no app password, no sync daemon on the machine controller.**

## The fstab entry

```
192.168.1.105:/mnt/user/Data  /mnt/nas-data  nfs  ro,soft,timeo=50,retrans=2,nofail,_netdev,x-systemd.automount,noauto  0  0
```

Every option is load-bearing on a machine controller:

| Option | Why |
|---|---|
| `ro` | The mill **physically cannot write upstream**. One-way is enforced by the kernel, not by a script remembering `copy` rather than `sync`. |
| `soft,timeo=50,retrans=2` | Errors after ~5 s instead of blocking forever. 🚨 A **hard** NFS mount — the default — hangs *indefinitely* on network loss. A blocked filesystem call on this machine is unacceptable. |
| `x-systemd.automount,noauto` | Mounts on first access. No NFS connection is held while idle and a dead NAS never delays boot. |
| `nofail,_netdev` | A missing NAS can never stop the machine booting. |

Verified 2026-09-06: write to the share from the mill is **refused**.

## Why a local copy rather than opening off the mount

`fetch-gcode.sh` rsyncs into `~/gcode` rather than pointing Axis at the mount. **The cut is then
independent of the network** — an NFS hiccup, a NAS reboot, or someone unplugging a switch cannot
affect a running job. Opening straight off the mount would work, but it puts the workshop network
in the path of a machining operation for no benefit.

⚠️ **No `--delete`.** Files removed upstream are left alone locally. Stale G-code is harmless; a
program vanishing between load and run is not.

## 🚨 Reading Nextcloud's data dir is safe — writing is not

Files live on disk at `<data>/<user>/files/...` in a plain tree, so reading is fine. **Writing
directly is not**: Nextcloud keeps a database index (`oc_filecache`) and files dropped in stay
invisible until `occ files:scan`. The `ro` mount makes that mistake impossible from here.

## Keep CAM output separated per machine

`CAM/Milo`, `CAM/PrintNC`, `CAM/Work`. **This mount deliberately reaches only `CAM/Milo`.**

Post-processor output is not portable between machines, and the dangerous case is not a file that
errors — it is one that **runs**, in a dialect close enough to be plausible, on a machine with a
different envelope and a different tool table. Scope makes that impossible rather than unlikely.
📌 Put the machine name in the filename too: once a file is open in Axis the folder context is
gone and the filename is all you see.

## Verified end to end (2026-09-06)

Desktop → Nextcloud → server (~3 s) → NFS → `~/gcode`. Content intact, `644 cnc:cnc`, mtime
preserved.

## Alternatives considered and rejected

- **Nextcloud desktop client** — bidirectional with no one-way mode. `~/gcode` would become an
  authority on what should exist upstream, so a deletion or corruption on the mill propagates and
  takes the CAM output with it. This machine has had power pulled mid-operation twice in one day.
- **`nextcloudcmd`** — same bidirectional problem. There is no `--download-only`.
- **`davfs2`** — a WebDAV mount blocks on network loss.
- **A custom client** — would have to reimplement WebDAV auth, retries, timeouts, checksums and
  credential storage. All unglamorous, all exactly where sync tools go wrong.
