# Reply, Forward, and Compose in Heathrow

Heathrow provides full email-style reply, forward, and compose functionality using your system's $EDITOR, similar to mutt.

## Features

- **Reply** (`r`) - Reply to the sender
- **Reply All** (`R`) - Reply to sender and all recipients
- **Forward** (`f`) - Forward message to new recipients
- **Compose** (`m`) - Create new message

## How It Works

1. Press the appropriate key while viewing a message
2. Your $EDITOR (default: vim) opens with a pre-formatted template
3. Edit the message, keeping the To: and Subject: headers
4. Save and exit to send (`:wq` in vim)
5. Exit without saving to cancel

## SMTP Configuration

Heathrow supports OAuth2 SMTP for Gmail and custom domains. Configure your domains in the `OAUTH2_DOMAINS` list inside `smtp_sender.rb`:
- gmail.com
- yourdomain.com (add your own)

The SmtpSender module (`lib/heathrow/smtp_sender.rb`) automatically detects configured domains and routes mail through your OAuth2 SMTP command (configurable in settings).

### OAuth2 Setup

Your OAuth2 credentials are stored in:
- `~/.heathrow/mail/[email].json` - Client credentials
- `~/.heathrow/mail/[email].txt` - Refresh token

The SMTP script handles token refresh automatically.

### Other Email Accounts

For non-OAuth2 accounts, configure SMTP settings when adding the source:
- SMTP server address
- SMTP port (usually 587 for TLS, 25 for plain)
- Username and password

## Message Templates

### Reply Template
```
To: original-sender@example.com
Subject: Re: Original Subject
# Lines starting with # will be ignored
# Write your message below this line
#==================================================

[Your reply here]

On 2025-08-25, sender wrote:
> Original message quoted
> with > prefix
```

### Reply All Template
```
To: sender@example.com, recipient1@example.com, recipient2@example.com
Subject: Re: Original Subject
[Rest same as reply]
```

### Forward Template
```
To: [Enter recipients]
Subject: Fwd: Original Subject
# Lines starting with # will be ignored
# Enter recipients and write your message
#==================================================

[Your introduction]

---------- Forwarded message ----------
From: original-sender@example.com
Date: 2025-08-25
Subject: Original Subject

[Original message content]
```

## Supported Sources

Sources with reply capability:
- **Gmail** - Full OAuth2 support via configurable SMTP command
- **IMAP** - Uses OAuth2 SMTP for supported domains or configured SMTP
- **Discord** - Bot/user messages to channels
- **Telegram** - Bot messages to chats

## Key Bindings

| Key | Action | Description |
|-----|--------|-------------|
| `r` | Reply | Reply to sender only |
| `R` | Reply All | Reply to all recipients |
| `f` | Forward | Forward to new recipients |
| `m` | Mail/Compose | Create new message |
| `Ctrl-R` | Refresh | Refresh all panes |

## Editor Tips

### Vim Configuration
Your vim is configured with:
```vim
setlocal tw=0 fo-=tcal ff=unix
```

This ensures:
- No automatic text wrapping
- Unix line endings
- Proper email formatting

### Canceling a Message
- Exit without saving: `:q!` in vim
- Or make no changes and save (detected as cancel)

## Troubleshooting

### Message Not Sending

1. Check `~/.heathrow/mail/.smtp.log` for errors
2. Verify OAuth2 credentials exist for your email
3. For new domains, add to `OAUTH2_DOMAINS` in `smtp_sender.rb`

### OAuth2 Token Issues

If you see token errors:
```bash
# Regenerate token
oauth2.py --generate_oauth2_token \
  --client_id=[your-client-id] \
  --client_secret=[your-secret] \
  --refresh_token=[your-refresh-token]
```

### SMTP Server Issues

For non-OAuth2 accounts, verify:
- SMTP server address is correct
- Port is appropriate (587 for TLS, 25 for plain)
- Username/password are correct
- Firewall allows outgoing SMTP

## Testing

Test the SMTP module:
```bash
ruby test_smtp_module.rb
```

Test sending from a specific source:
```bash
ruby test_gmail_send.rb
```

## Implementation Details

The reply/forward system consists of:

1. **MessageComposer** (`lib/heathrow/message_composer.rb`)
   - Creates templates
   - Launches editor
   - Parses composed messages

2. **SmtpSender** (`lib/heathrow/smtp_sender.rb`)
   - Routes to OAuth2 SMTP for configured domains
   - Falls back to standard SMTP for others
   - Handles error reporting

3. **Source Integration**
   - Each source implements `can_reply?` and `send_message`
   - Threading headers (In-Reply-To, References) preserved

## Security Notes

- OAuth2 tokens stored in `~/.heathrow/mail/`
- No passwords stored in Heathrow database for OAuth2 accounts
- Temporary message files deleted after sending
- SMTP passwords encrypted in source config