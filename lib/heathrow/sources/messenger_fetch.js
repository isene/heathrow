#!/usr/bin/env node
// Fetch Messenger inbox threads + message history using Playwright headless browser
// Called by messenger.rb, outputs JSON to stdout
// Facebook uses E2EE so we must scrape the rendered DOM, not GraphQL

const { firefox } = require('playwright');
const path = require('path');
const fs = require('fs');
const { execSync } = require('child_process');

const COOKIE_FILE = path.join(process.env.HOME, '.heathrow', 'cookies', 'messenger.json');
const TIMEOUT = 30000;
const MAX_THREADS = 10;   // How many threads to fetch history for
const MSG_PER_THREAD = 10; // Messages to extract per thread
const DEBUG = process.argv.includes('--debug');

// Extract fresh cookies from Firefox's cookies.sqlite
function refreshCookiesFromFirefox() {
  try {
    const profilesDir = path.join(process.env.HOME, '.mozilla', 'firefox');
    const profiles = fs.readdirSync(profilesDir);
    let cookiesDb = null;
    for (const p of profiles) {
      const candidate = path.join(profilesDir, p, 'cookies.sqlite');
      if (fs.existsSync(candidate)) { cookiesDb = candidate; break; }
    }
    if (!cookiesDb) return null;

    const tmp = `/tmp/heathrow_msng_fetch_${process.pid}.sqlite`;
    fs.copyFileSync(cookiesDb, tmp);

    const names = ['c_user', 'xs', 'datr', 'fr', 'sb', 'wd'];
    const cookies = {};

    for (const name of names) {
      try {
        const result = execSync(
          `sqlite3 "${tmp}" "SELECT value FROM moz_cookies WHERE name = '${name}' AND (host LIKE '%messenger.com' OR host LIKE '%facebook.com') ORDER BY expiry DESC LIMIT 1"`,
          { encoding: 'utf8', timeout: 5000 }
        ).trim();
        if (result) cookies[name] = decodeURIComponent(result);
      } catch (e) {}
    }

    try { fs.unlinkSync(tmp); } catch (e) {}

    if (cookies.c_user && cookies.xs) {
      const dir = path.dirname(COOKIE_FILE);
      if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
      fs.writeFileSync(COOKIE_FILE, JSON.stringify(cookies));
      fs.chmodSync(COOKIE_FILE, 0o600);
      return cookies;
    }
    return null;
  } catch (e) {
    return null;
  }
}

async function fetchMessengerThreads() {
  let browser;
  try {
    // Always refresh cookies from Firefox
    let cookies = refreshCookiesFromFirefox();
    if (!cookies) {
      if (fs.existsSync(COOKIE_FILE)) {
        cookies = JSON.parse(fs.readFileSync(COOKIE_FILE, 'utf8'));
      } else {
        cookies = {};
      }
    }
    if (!cookies.c_user || !cookies.xs) {
      console.log(JSON.stringify({ error: 'missing_cookies', threads: [] }));
      return;
    }

    const makeCookies = (domain) => Object.entries(cookies).map(([name, value]) => ({
      name, value: String(value), domain, path: '/',
      httpOnly: true, secure: true, sameSite: 'None'
    }));

    browser = await firefox.launch({ headless: true });
    const context = await browser.newContext({
      userAgent: 'Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0',
      viewport: { width: 1280, height: 720 }
    });

    await context.addCookies([...makeCookies('.messenger.com'), ...makeCookies('.facebook.com')]);
    const page = await context.newPage();

    await page.goto('https://www.messenger.com/t/', {
      waitUntil: 'domcontentloaded', timeout: TIMEOUT
    });

    // Wait for thread list
    try {
      await page.waitForSelector('a[href*="/t/"]', { timeout: 15000 });
    } catch (e) {
      await page.waitForTimeout(5000);
    }

    // Dismiss PIN dialog
    try {
      const pinInput = await page.$('input[type="text"], input[type="tel"], input[aria-label*="PIN"]');
      if (pinInput) {
        for (const digit of '314159') {
          await page.keyboard.press(digit);
          await page.waitForTimeout(100);
        }
        await page.waitForTimeout(3000);
      }
    } catch (e) {}

    // Dismiss modals
    try {
      const closeBtn = await page.$('[aria-label="Close"], [aria-label="Dismiss"]');
      if (closeBtn) await closeBtn.click();
      await page.waitForTimeout(1000);
    } catch (e) {}

    await page.waitForTimeout(2000);

    if (page.url().includes('login') || page.url().includes('checkpoint')) {
      console.log(JSON.stringify({ error: 'login_required', threads: [] }));
      return;
    }

    // Get thread list from sidebar DOM
    const threadList = await page.evaluate(() => {
      const skipNames = /^(Media & files|Privacy & support|Marketplace|Message Requests|Archived Chats|Communities|Chats)$/i;
      const skipSnippets = /^(Messages and calls are secured|End-to-end encrypted|Active \d|Active now|You're now connected|Say hi to your new)/i;
      const statusPatterns = /^(Active now|Active \d+[hm] ago)$/i;
      const results = [];
      const links = document.querySelectorAll('a[href*="/t/"]');
      const seen = new Set();

      for (const link of links) {
        const match = link.href.match(/\/t\/(\d+)/);
        if (!match || seen.has(match[1])) continue;
        seen.add(match[1]);

        const row = link.closest('[role="row"], [role="listitem"]') || link.parentElement;
        if (!row) continue;

        const spans = Array.from(row.querySelectorAll('span'))
          .map(s => s.textContent.trim())
          .filter(t => t.length > 0 && t.length < 200);
        if (spans.length === 0) continue;

        let name = null;
        for (const s of spans) {
          if (statusPatterns.test(s) || skipNames.test(s) || s.includes(' unread')) continue;
          name = s;
          break;
        }
        if (!name || skipNames.test(name)) continue;

        const unread = row.innerHTML.includes('Unread') ||
                       row.querySelector('[aria-label*="unread"]') !== null;

        results.push({ id: match[1], name, unread });
      }
      return results;
    });

    if (DEBUG) {
      console.error(`Found ${threadList.length} threads in sidebar`);
    }

    // Visit each thread and extract messages from the rendered conversation
    const threads = [];
    const toVisit = threadList.slice(0, MAX_THREADS);

    for (const thread of toVisit) {
      try {
        await page.goto(`https://www.messenger.com/t/${thread.id}`, {
          waitUntil: 'domcontentloaded', timeout: 15000
        });

        // Wait for messages to render
        try {
          await page.waitForSelector('[role="row"]', { timeout: 8000 });
        } catch (e) {
          await page.waitForTimeout(3000);
        }
        await page.waitForTimeout(1500);

        // Extract messages from the conversation view
        const messages = await page.evaluate(({threadName, msgLimit}) => {
          const msgs = [];
          const skipText = /^(Messages and calls are secured|New messages and calls are secured|End-to-end encrypted|You're now connected|Say hi to|You (created|named) the group|Only people in this chat can)/i;
          const datePattern = /^(January|February|March|April|May|June|July|August|September|October|November|December|\d{1,2}\/\d{1,2}|Yesterday|Today|Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)/i;

          // Messages are in [role="row"] inside [role="main"]
          const main = document.querySelector('[role="main"]');
          if (!main) return [];

          const rows = main.querySelectorAll('[role="row"]');
          let currentSender = threadName;

          for (const row of rows) {
            const fullText = row.textContent.trim();

            // Skip date separator rows
            if (datePattern.test(fullText) && fullText.length < 60) continue;
            // Skip E2E banner
            if (skipText.test(fullText)) continue;
            // Skip empty or header rows
            if (!fullText || fullText.length < 2) continue;

            // Get all [dir="auto"] spans in this row for sender + message parsing
            const spans = Array.from(row.querySelectorAll('[dir="auto"]'))
              .map(el => el.textContent.trim())
              .filter(t => t.length > 0);

            if (spans.length === 0) continue;

            // Detect sender: "You sent" or a short name before the message
            let sender = currentSender;
            let messageText = '';

            if (spans[0] === 'You sent' || fullText.startsWith('You sent')) {
              sender = 'You';
              // Message text is in subsequent spans (skip "You sent" and "Enter")
              messageText = spans.filter(s => s !== 'You sent' && s !== 'Enter')
                .find(s => s.length > 1 && !datePattern.test(s) && !skipText.test(s)) || '';
            } else {
              // First span might be sender name (short, no spaces typically for first name)
              // Message text is duplicated in spans (Messenger renders it twice)
              const firstSpan = spans[0];
              const restSpans = spans.slice(1).filter(s => s !== 'Enter');

              if (firstSpan.length < 30 && restSpans.length > 0 && firstSpan !== restSpans[0]) {
                // First span is likely sender name
                sender = firstSpan;
                currentSender = sender;
                messageText = restSpans[0] || '';
              } else if (restSpans.length > 0) {
                messageText = firstSpan;
              } else {
                messageText = firstSpan;
              }
            }

            // Clean up: Messenger often duplicates the message text
            if (!messageText || messageText === 'Enter' || skipText.test(messageText)) continue;
            if (datePattern.test(messageText) && messageText.length < 60) continue;

            msgs.push({ text: messageText, sender });
          }

          // Newest last in DOM, reverse for newest-first
          const seen = new Set();
          return msgs.reverse().filter(m => {
            if (seen.has(m.text)) return false;
            seen.add(m.text);
            return true;
          }).slice(0, msgLimit);
        }, {threadName: thread.name, msgLimit: MSG_PER_THREAD});

        if (DEBUG) {
          console.error(`Thread ${thread.name}: ${messages.length} messages`);
        }

        // Assign sequential timestamps (we don't have real ones from DOM)
        const now = Date.now() / 1000;
        const msgsWithTs = messages.map((m, i) => ({
          id: `${thread.id}_${i}`,
          sender: m.sender,
          text: m.text,
          timestamp: Math.floor(now - (messages.length - 1 - i) * 60)  // 1 min apart
        }));

        threads.push({
          id: thread.id,
          name: thread.name,
          unread: thread.unread,
          messages: msgsWithTs
        });

      } catch (e) {
        if (DEBUG) console.error(`Failed thread ${thread.id}: ${e.message}`);
        // Still include the thread with no messages
        threads.push({ id: thread.id, name: thread.name, unread: thread.unread, messages: [] });
      }
    }

    console.log(JSON.stringify({ threads, source: 'dom' }));

  } catch (err) {
    console.log(JSON.stringify({ error: err.message, threads: [] }));
  } finally {
    if (browser) await browser.close();
  }
}

fetchMessengerThreads();
