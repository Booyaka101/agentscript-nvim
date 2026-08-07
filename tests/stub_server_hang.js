// Test stub: accepts input but never answers, to exercise the verify timeout
// (and its kill-the-child cleanup).
process.stdin.on('data', () => {});
setInterval(() => {}, 1 << 30);
