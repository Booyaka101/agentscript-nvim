// Test stub standing in for `sf`: replays output captured from a real org
// (tests/fixtures/sf) and appends {args, cwd, pid} to $FAKE_SF_LOG.
// $FAKE_SF_MODE picks the validate outcome: pass, fail, fail-nodata (the same
// failure without data.errors), unicode, noorg, unknown, hang, and expired
// for preview send.
const fs = require('fs');
const path = require('path');

const args = process.argv.slice(2);
const fixtures = path.join(__dirname, 'fixtures', 'sf');
const log = process.env.FAKE_SF_LOG;
const entries = log && fs.existsSync(log) ? fs.readFileSync(log, 'utf8').split('\n').filter(Boolean) : [];
if (log) fs.appendFileSync(log, JSON.stringify({ args, cwd: process.cwd(), pid: process.pid }) + '\n');

function replay(name, edit) {
  const envelope = JSON.parse(fs.readFileSync(path.join(fixtures, name + '.json'), 'utf8'));
  if (edit) edit(envelope);
  process.stdout.write(JSON.stringify(envelope, null, 2) + '\n');
  process.exitCode = envelope.status;
}

const mode = process.env.FAKE_SF_MODE || 'pass';
const sub = args.slice(0, 3).join(' ');
if (args[0] === 'version') {
  replay('version', (v) => (v.rootPath = process.env.FAKE_SF_ROOT));
} else if (mode === 'hang') {
  setTimeout(() => {}, 600000);
} else if (mode === 'unknown') {
  process.stderr.write(fs.readFileSync(path.join(fixtures, 'unknown-command.stderr.txt'), 'utf8'));
  process.exitCode = 127;
} else if (mode === 'noorg') {
  replay('no-default-org');
} else if (sub === 'agent validate authoring-bundle') {
  if (mode === 'fail-nodata') replay('validate-fail', (e) => delete e.data);
  else replay({ pass: 'validate-pass', fail: 'validate-fail', unicode: 'validate-unicode' }[mode]);
} else if (sub === 'agent preview start') {
  replay('preview-start');
} else if (sub === 'agent preview send' && mode === 'expired') {
  replay('preview-session-invalid');
} else if (sub === 'agent preview send') {
  const sent = entries.filter((l) => JSON.parse(l).args[2] === 'send').length;
  replay('preview-send-' + ((sent % 3) + 1));
} else if (sub === 'agent preview end') {
  replay('preview-end');
} else {
  process.stderr.write('fake_sf: unhandled ' + args.join(' ') + '\n');
  process.exitCode = 2;
}
