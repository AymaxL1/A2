// E1 — minimal Electron closed-loop smoke test.
// E1a: floating/transparent/frameless/click-through/all-workspaces overlay window,
//      self-check flag readback + capturePage() PNG proof.
// E1b: node:net UDS server inside the Electron main process, round-tripped by
//      a spawned *external* `node` client process.
//
// HARD RULE: no human is watching this run. The app must not linger and must
// not open DevTools. It force-quits at HARD_TIMEOUT_MS regardless of what
// step it's on.
'use strict';

const { app, BrowserWindow, screen } = require('electron');
const net = require('node:net');
const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');

const T0 = Date.now();
const elapsed = () => Date.now() - T0;

const SPIKE_DIR = __dirname;
const SOCKET_PATH = `/tmp/e1-electron-smoke-${process.pid}.sock`;
const SELFCHECK_JSON_PATH = path.join(SPIKE_DIR, 'selfcheck-result.json');
const SCREENSHOT_PATH = path.join(SPIKE_DIR, 'e1a-capture.png');
const HARD_TIMEOUT_MS = 8000;

// Node binary for the *external* UDS client — must be a real `node`, not the
// Electron binary itself. run.sh exports NODE_BIN to the user-mode Node we
// installed to scratchpad; fall back to whatever `node` is on PATH.
const NODE_BIN = process.env.NODE_BIN || 'node';

const result = {
  meta: {
    platform: process.platform,
    arch: process.arch,
    electron: process.versions.electron,
    chrome: process.versions.chrome,
    node_electron_internal: process.versions.node,
    node_external_bin: NODE_BIN,
  },
  e1a: null,
  e1b: null,
  timings_ms: {},
};

let udsServer = null;
let quitting = false;

function cleanupSocket() {
  try {
    if (fs.existsSync(SOCKET_PATH)) fs.unlinkSync(SOCKET_PATH);
  } catch (e) {
    console.error('[cleanup] socket unlink failed:', e.message);
  }
}

function finishAndQuit(reason) {
  if (quitting) return;
  quitting = true;
  result.timings_ms.total_before_quit = elapsed();
  result.quit_reason = reason;
  try {
    fs.writeFileSync(SELFCHECK_JSON_PATH, JSON.stringify(result, null, 2));
  } catch (e) {
    console.error('[finish] failed to write selfcheck json:', e.message);
  }
  console.log('SELFCHECK_JSON_BEGIN');
  console.log(JSON.stringify(result, null, 2));
  console.log('SELFCHECK_JSON_END');
  if (udsServer) {
    try {
      udsServer.close();
    } catch (_) {}
  }
  cleanupSocket();
  app.quit();
}

// Hard cap: whatever happens, we are gone by T0+8000ms.
const hardTimer = setTimeout(() => finishAndQuit('hard_timeout_8s'), HARD_TIMEOUT_MS);

function runE1b() {
  return new Promise((resolve) => {
    const t1b0 = elapsed();
    cleanupSocket(); // stale socket from a crashed prior run, if any

    udsServer = net.createServer((socket) => {
      let buf = '';
      socket.on('data', (d) => {
        buf += d.toString('utf8');
      });
      socket.on('end', () => {
        let clientMsg;
        try {
          clientMsg = JSON.parse(buf);
        } catch (e) {
          clientMsg = { parse_error: e.message, raw: buf };
        }
        const reply = {
          pong: true,
          server_pid: process.pid,
          server_is_electron_main: true,
          received: clientMsg,
          ts: Date.now(),
        };
        socket.end(JSON.stringify(reply));
      });
      socket.on('error', (e) => console.error('[uds-server] socket error:', e.message));
    });

    udsServer.on('error', (e) => {
      resolve({ ok: false, error: `server_error: ${e.message}` });
    });

    udsServer.listen(SOCKET_PATH, () => {
      const clientScript = path.join(SPIKE_DIR, 'uds-client.js');
      const child = spawn(NODE_BIN, [clientScript, SOCKET_PATH], {
        env: { ...process.env },
      });

      let out = '';
      let err = '';
      child.stdout.on('data', (d) => (out += d.toString()));
      child.stderr.on('data', (d) => (err += d.toString()));

      const clientTimeout = setTimeout(() => {
        child.kill();
        resolve({ ok: false, error: 'client_spawn_timeout', stdout: out, stderr: err });
      }, 5000);

      child.on('exit', (code) => {
        clearTimeout(clientTimeout);
        const m = out.match(/CLIENT_RESULT:(.*)/s);
        let serverReplyEchoedBack = null;
        let roundtripOk = false;
        if (m) {
          try {
            serverReplyEchoedBack = JSON.parse(m[1].trim());
            roundtripOk =
              serverReplyEchoedBack &&
              serverReplyEchoedBack.pong === true &&
              serverReplyEchoedBack.received &&
              serverReplyEchoedBack.received.hello === 'from-external-node-client';
          } catch (_) {}
        }
        resolve({
          ok: code === 0 && roundtripOk,
          exit_code: code,
          roundtrip_ok: roundtripOk,
          socket_path: SOCKET_PATH,
          client_node_bin: NODE_BIN,
          server_reply_seen_by_client: serverReplyEchoedBack,
          client_stderr: err || null,
          duration_ms: elapsed() - t1b0,
        });
      });
    });
  });
}

async function runE1a(win) {
  const t1a0 = elapsed();

  win.setAlwaysOnTop(true, 'screen-saver');
  win.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
  win.setIgnoreMouseEvents(true, { forward: true });

  // let the compositor settle a beat before reading flags / capturing
  await new Promise((r) => setTimeout(r, 300));

  const display = screen.getPrimaryDisplay();
  const selfcheck = {
    isAlwaysOnTop: win.isAlwaysOnTop(),
    isVisibleOnAllWorkspaces: win.isVisibleOnAllWorkspaces(),
    isVisible: win.isVisible(),
    isFocused: win.isFocused(),
    isResizable: win.isResizable(),
    isFullScreenable: win.isFullScreenable(),
    hasShadow: win.hasShadow(),
    bounds: win.getBounds(),
    primaryDisplayWorkArea: display.workAreaSize,
    // Electron has no getter for the ignoreMouseEvents flag itself — it's
    // fire-and-forget. Noted as a verification gap; behavior can only be
    // confirmed by manual click-through testing (see README checklist).
    ignoreMouseEventsGetterAvailable: false,
  };

  let capture = { ok: false };
  try {
    const image = await win.webContents.capturePage();
    const png = image.toPNG();
    fs.writeFileSync(SCREENSHOT_PATH, png);
    const size = image.getSize();
    capture = {
      ok: true,
      file: path.basename(SCREENSHOT_PATH),
      bytes: png.length,
      width: size.width,
      height: size.height,
    };
  } catch (e) {
    capture = { ok: false, error: e.message };
  }

  return {
    selfcheck,
    capture,
    duration_ms: elapsed() - t1a0,
  };
}

app.whenReady().then(async () => {
  // Never show a dock icon bounce / never focus-steal; this is a headless-ish
  // smoke test, not an interactive session.
  const win = new BrowserWindow({
    width: 240,
    height: 240,
    transparent: true,
    frame: false,
    alwaysOnTop: true,
    hasShadow: false,
    resizable: false,
    skipTaskbar: true,
    show: true,
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      backgroundThrottling: false,
    },
  });

  // Explicitly never open DevTools (per spec: no human present, no leftover UI).
  win.webContents.on('devtools-opened', () => win.webContents.closeDevTools());

  await win.loadFile(path.join(SPIKE_DIR, 'pet.html'));

  try {
    result.e1a = await runE1a(win);
  } catch (e) {
    result.e1a = { error: e.message };
  }

  try {
    result.e1b = await runE1b();
  } catch (e) {
    result.e1b = { error: e.message };
  }

  finishAndQuit('smoke_complete');
});

app.on('window-all-closed', () => {
  // Don't let macOS keep the app "running" with no windows; we control quit
  // explicitly via finishAndQuit, but guard against the default no-op here.
  if (!quitting) finishAndQuit('window_all_closed');
});

process.on('exit', () => {
  clearTimeout(hardTimer);
});
