#!/usr/bin/env python3
"""Fetch messages from a single Messenger conversation via Firefox Marionette.

Usage: messenger_fetch_thread.py <thread_id>

Connects to Firefox Marionette, navigates to the conversation,
scrapes visible messages, returns JSON to stdout.
"""

import json
import sys
import time

DEBUG = '--debug' in sys.argv
THREAD_ID = None

for arg in sys.argv[1:]:
    if arg != '--debug' and arg.isdigit():
        THREAD_ID = arg


def debug(msg):
    if DEBUG:
        print(f"[thread-fetch] {msg}", file=sys.stderr)


def main():
    if not THREAD_ID:
        print(json.dumps({"error": "No thread ID provided", "messages": []}))
        return

    try:
        from marionette_driver.marionette import Marionette
    except ImportError:
        print(json.dumps({"error": "marionette_driver not installed", "messages": []}))
        return

    client = None
    try:
        client = Marionette(host='localhost', port=2828)
        client.start_session()
        debug("Connected")

        # Find Messenger tab
        for handle in client.window_handles:
            client.switch_to_window(handle)
            if 'messenger.com' in client.get_url():
                break
        else:
            print(json.dumps({"error": "No Messenger tab found", "messages": []}))
            return

        # Navigate to the conversation
        target_url = f"https://www.messenger.com/t/{THREAD_ID}"
        current_url = client.get_url()
        if f"/t/{THREAD_ID}" not in current_url:
            debug(f"Navigating to {target_url}")
            client.navigate(target_url)
            time.sleep(2)
        else:
            debug("Already on target conversation")

        # Scrape messages from the main content area
        messages = client.execute_script("""
const msgs = [];
const mainArea = document.querySelector('[role="main"]');
if (!mainArea) return msgs;

// Find all message groups - each group has a sender
const groups = mainArea.querySelectorAll('[role="row"]');

for (const group of groups) {
    // Get text content from dir="auto" spans (actual message text)
    const textEls = Array.from(group.querySelectorAll('[dir="auto"]'));
    if (textEls.length === 0) continue;

    // Filter out UI chrome
    const texts = textEls
        .map(e => e.textContent.trim())
        .filter(t => {
            if (t.length < 1 || t.length > 5000) return false;
            if (/^(Active now|Active \\d|Seen by|You sent|\\d+ (hour|minute|day|week)|Loading|Replying to|End-to-end encrypted|Messenger|Media & files|Privacy & support)/i.test(t)) return false;
            if (/^(Today|Yesterday)$/i.test(t)) return false;
            if (/^\\d{1,2}:\\d{2}\\s*(AM|PM)?$/i.test(t)) return false;
            if (/^\\w{3} \\d{1,2}, \\d{4}$/i.test(t)) return false;
            return true;
        });
    if (texts.length === 0) continue;

    const text = texts.join(' ');
    if (text.length < 1) continue;

    // Try sender from img alt
    let sender = '';
    const img = group.querySelector('img[alt]');
    if (img && img.alt && img.alt.length < 60 && !/^\\d/.test(img.alt)) {
        sender = img.alt;
    }

    msgs.push({sender: sender, text: text});
}
return msgs;
""") or []

        debug(f"Found {len(messages)} raw messages")

        # Deduplicate consecutive identical texts
        deduped = []
        prev_text = ''
        for m in messages:
            if m['text'] != prev_text:
                deduped.append(m)
                prev_text = m['text']

        debug(f"After dedup: {len(deduped)} messages")
        print(json.dumps({"messages": deduped}))

    except ConnectionRefusedError:
        print(json.dumps({"error": "Cannot connect to Marionette on port 2828", "messages": []}))
    except Exception as e:
        print(json.dumps({"error": str(e), "messages": []}))
    finally:
        if client:
            try:
                client.delete_session()
            except Exception:
                pass


if __name__ == '__main__':
    main()
