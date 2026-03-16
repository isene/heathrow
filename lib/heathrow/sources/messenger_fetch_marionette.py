#!/usr/bin/env python3
"""Fetch Messenger DM threads and messages via Firefox Marionette.

Connects to a running Firefox instance on Marionette port 2828,
finds the Messenger tab, scrapes thread list and message history
from the DOM. Outputs JSON to stdout, debug info to stderr.

Requires: marionette_driver (pip install marionette_driver)
"""

import json
import sys

MAX_THREADS = 20
DEBUG = '--debug' in sys.argv


def debug(msg):
    if DEBUG:
        print(f"[marionette] {msg}", file=sys.stderr)


def output_error(message):
    print(json.dumps({"error": message, "threads": []}))
    sys.exit(0)


def find_messenger_tab(client):
    """Find the tab with messenger.com open."""
    handles = client.window_handles
    debug(f"Found {len(handles)} tabs")

    for handle in handles:
        client.switch_to_window(handle)
        url = client.get_url()
        debug(f"  Tab: {url[:80]}")
        if 'messenger.com' in url:
            debug(f"Found Messenger tab: {url}")
            return handle

    return None


SCRAPE_THREADS_JS = """
const skipNames = /^(Media & files|Privacy & support|Marketplace|Message Requests|Archived Chats|Communities|Chats)$/i;
const statusPatterns = /^(Active now|Active \\d+[hm] ago)$/i;
const results = [];
const links = document.querySelectorAll('a[href*="/t/"]');
const seen = new Set();

for (const link of links) {
    const match = link.href.match(/\\/t\\/(\\d+)/);
    if (!match || seen.has(match[1])) continue;
    seen.add(match[1]);

    const row = link.closest('[role="row"], [role="listitem"]') || link.parentElement;
    if (!row) continue;

    const spans = Array.from(row.querySelectorAll('span'))
        .map(s => s.textContent.trim())
        .filter(t => t.length > 0 && t.length < 200);
    if (spans.length === 0) continue;

    let name = null;
    let snippet = '';
    for (const s of spans) {
        if (statusPatterns.test(s) || skipNames.test(s) || s.includes(' unread')) continue;
        if (!name) { name = s; continue; }
        if (!snippet && s !== name && s.length > 1) { snippet = s; }
    }
    if (!name || skipNames.test(name)) continue;

    const unread = row.innerHTML.includes('Unread') ||
                   row.querySelector('[aria-label*="unread"]') !== null;

    results.push({id: match[1], name: name, unread: unread, snippet: snippet});
}
return results;
"""



def main():
    try:
        from marionette_driver.marionette import Marionette
    except ImportError:
        output_error("marionette_driver not installed (pip install marionette_driver)")

    client = None
    try:
        client = Marionette(host='localhost', port=2828)
        client.start_session()
        debug("Connected to Marionette")

        handle = find_messenger_tab(client)
        if not handle:
            output_error("No Messenger tab found in Firefox")

        # Scrape thread list + snippets from the sidebar (no navigation needed)
        debug("Scraping thread list from sidebar...")
        thread_list = client.execute_script(SCRAPE_THREADS_JS)

        if not thread_list:
            debug("No threads found in sidebar")
            print(json.dumps({"threads": [], "source": "marionette"}))
            return

        debug(f"Found {len(thread_list)} threads in sidebar")

        threads = []
        for thread in thread_list[:MAX_THREADS]:
            snippet = thread.get('snippet', '')
            debug(f"  {thread['name']}: snippet={snippet[:50] if snippet else '(none)'}, unread={thread.get('unread')}")
            threads.append({
                "id": thread['id'],
                "name": thread['name'],
                "unread": thread.get('unread', False),
                "snippet": snippet,
                "messages": []
            })

        print(json.dumps({"threads": threads, "source": "marionette"}))

    except ConnectionRefusedError:
        output_error("Cannot connect to Firefox Marionette on port 2828. Start Firefox with --marionette.")
    except Exception as e:
        output_error(str(e))
    finally:
        if client:
            try:
                client.delete_session()
                debug("Session deleted")
            except Exception:
                pass


if __name__ == '__main__':
    main()
