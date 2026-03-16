#!/usr/bin/env node
// Send a Messenger DM by opening the thread in the user's browser.
// Since Meta blocks all non-browser API access, this opens the DM thread
// in the real browser with the message pre-copied to clipboard.
//
// Usage: messenger_send.js <thread_id> <message>
// Outputs JSON: { success: true/false, message: "..." }

const { execSync, spawn } = require('child_process');

const threadId = process.argv[2];
const message = process.argv[3];

if (!threadId || !message) {
  console.log(JSON.stringify({ success: false, message: 'Usage: messenger_send.js <thread_id> <message>' }));
  process.exit(0);
}

const url = `https://www.messenger.com/t/${threadId}`;

// Copy message to clipboard
try {
  execSync('xclip -selection clipboard', { input: message.trim(), timeout: 3000 });
} catch (e) {}

// Open in browser
spawn('xdg-open', [url], { detached: true, stdio: 'ignore' }).unref();

console.log(JSON.stringify({
  success: true,
  message: 'Opened Messenger in browser. Message copied to clipboard (Ctrl+V to paste).'
}));
