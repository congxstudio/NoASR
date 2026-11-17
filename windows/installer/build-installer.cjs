const fs = require('node:fs');
const path = require('node:path');
const { build, Platform, Arch } = require('electron-builder');

const appDir = path.resolve(process.argv[2]);
const version = process.argv[3];
if (!fs.existsSync(path.join(appDir, 'NoASR.exe')) || !/^\d+\.\d+\.\d+(?:-[\w.]+)?$/.test(version)) {
  throw new Error('Missing NoASR payload or invalid version');
}
process.env.CSC_IDENTITY_AUTO_DISCOVERY = 'false';
build({
  projectDir: __dirname,
  prepackaged: appDir,
  targets: Platform.WINDOWS.createTarget('nsis', Arch.x64),
  publish: 'never',
  config: { extraMetadata: { version } },
}).catch(error => { console.error(error); process.exitCode = 1; });
