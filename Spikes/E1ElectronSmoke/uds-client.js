// E1b — external Node client. Deliberately run as a plain `node` process
// (NOT via ELECTRON_RUN_AS_NODE) to prove a real external process can talk
// to the Electron-hosted UDS server over node:net.
'use strict';
const net = require('net');

const socketPath = process.argv[2];
if (!socketPath) {
  console.error('CLIENT_ERROR:missing socket path arg');
  process.exit(1);
}

const payload = {
  hello: 'from-external-node-client',
  pid: process.pid,
  execPath: process.execPath,
  isElectron: !!process.versions.electron,
  ts: Date.now(),
};

const client = net.createConnection(socketPath, () => {
  // half-close our write side so the server's `end` handler (which waits
  // for a complete message before replying) actually fires.
  client.end(JSON.stringify(payload));
});

let buf = '';
client.setTimeout(5000);

client.on('data', (d) => {
  buf += d.toString('utf8');
});

client.on('end', () => {
  console.log('CLIENT_RESULT:' + buf);
  process.exit(0);
});

client.on('timeout', () => {
  console.error('CLIENT_ERROR:timeout waiting for server reply');
  client.destroy();
  process.exit(1);
});

client.on('error', (e) => {
  console.error('CLIENT_ERROR:' + e.message);
  process.exit(1);
});
