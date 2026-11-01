// Both processes belong to this test. A timeout must stop the child before returning.
const fs = require('fs');
const { spawn } = require('child_process');
if (process.argv[2] === 'child') {
  const marker = process.argv[3];
  fs.writeFileSync(marker, 'started');
  setInterval(() => fs.appendFileSync(marker, '.'), 20);
} else {
  spawn(process.execPath, [__filename, 'child', process.argv[2]], { stdio: 'inherit' });
  setInterval(() => {}, 1000);
}
