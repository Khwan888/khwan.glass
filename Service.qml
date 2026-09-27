import QtQuick
import Quickshell
import Quickshell.Io

// Headless Glass service: runs `glass-ctl init` once at shell startup so
// hand-edits in looknfeel.lua are adopted into glass.json before the panel
// opens, and exposes the khwan.glass IPC surface for CLI control.
Item {
  id: root

  readonly property string ctl:
    Quickshell.env("HOME") + "/.config/omarchy/plugins/khwan.glass/scripts/glass-ctl"

  Component.onCompleted: if (!initProc.running) initProc.running = true

  Process {
    id: initProc
    command: [root.ctl, "init"]
    stdout: StdioCollector { waitForEnd: true }
  }

  IpcHandler {
    target: "khwan.glass.service"

    function get(): string {
      var result = null
      // Synchronous exec isn't available in IpcHandler context; spawn and
      // answer from cached state file instead.
      return readState()
    }

    function readState(): string {
      var file = Quickshell.env("HOME") + "/.local/state/omarchy/glass.json"
      var xhr = new XMLHttpRequest()
      xhr.open("GET", "file://" + file, false)
      try { xhr.send() } catch (e) { return JSON.stringify({ ok: false, error: "no state" }) }
      return JSON.stringify({ ok: true, state: JSON.parse(xhr.responseText) })
    }

    function set(payload: string): string {
      Quickshell.execDetached([root.ctl, "set", payload])
      return JSON.stringify({ ok: true, queued: payload })
    }

    function preset(name: string): string {
      Quickshell.execDetached([root.ctl, "preset", name])
      return JSON.stringify({ ok: true, queued: name })
    }

    function sync(): string {
      Quickshell.execDetached([root.ctl, "sync"])
      return JSON.stringify({ ok: true, queued: "sync" })
    }

    function round(arg: string): string {
      Quickshell.execDetached([root.ctl, "round", arg])
      return JSON.stringify({ ok: true, queued: arg })
    }

    function savepreset(name: string): string {
      Quickshell.execDetached([root.ctl, "savepreset", name])
      return JSON.stringify({ ok: true, queued: name })
    }

    function delpreset(name: string): string {
      Quickshell.execDetached([root.ctl, "delpreset", name])
      return JSON.stringify({ ok: true, queued: name })
    }

    function revert(): string {
      Quickshell.execDetached([root.ctl, "revert"])
      return JSON.stringify({ ok: true, queued: true })
    }
  }
}
