# WhatsApp and Telegram Setup Guide for Heathrow

This guide helps you set up WhatsApp and Telegram sources in Heathrow to receive messages from these platforms.

## WhatsApp Setup

WhatsApp integration requires a separate API server that implements the WhatsApp Web protocol.

### Prerequisites

1. **Go Language** - Required for the WhatsApp API server
   ```bash
   sudo apt install golang-go
   ```

2. **WhatsApp API Server** - A REST API wrapper for WhatsApp Web
   - The server needs to be running before setting up the source
   - Default port: 8080

### Quick Setup

1. Start the WhatsApp API server (in a separate terminal):
   ```bash
   # Clone and run the server
   git clone [whatsmeow-api-repo]
   cd whatsmeow-api
   go run main.go
   ```

2. Run the WhatsApp setup script:
   ```bash
   ruby setup_whatsapp.rb
   ```

3. Choose authentication method:
   - **QR Code** (default): Scan with WhatsApp mobile app
   - **Pairing Code**: Enter code in WhatsApp settings

### Authentication Methods

#### QR Code Method
1. Open WhatsApp on your phone
2. Go to Settings → Linked Devices
3. Tap "Link a Device"
4. Scan the QR code displayed in terminal

#### Pairing Code Method
1. Provide your phone number during setup
2. Receive an 8-digit pairing code
3. In WhatsApp: Settings → Linked Devices → Link with phone number
4. Enter the pairing code

### Configuration

The WhatsApp source supports these settings:

```ruby
{
  api_url: 'http://localhost:8080',  # API server URL
  device_id: 'unique_device_id',     # Device identifier
  fetch_limit: 50,                   # Messages per fetch
  incremental_sync: true,            # Only fetch new messages
  use_pairing_code: false,           # Use QR code by default
  phone_number: '1234567890',        # For pairing code only
  polling_interval: 60               # Check every minute
}
```

### Message Types Supported

- Text messages
- Images, videos, audio
- Documents and files
- Location sharing
- Contact cards
- Stickers
- Group messages

## Telegram Setup

Telegram offers two integration methods: Bot API (simple) or User Account (full access).

### Method 1: Telegram Bot (Recommended for Start)

#### Creating a Bot

1. Open Telegram and search for **@BotFather**
2. Send `/newbot` command
3. Choose a name for your bot
4. Choose a username (must end in 'bot')
5. Copy the bot token provided

#### Setup

Run the Telegram setup script:
```bash
ruby setup_telegram.rb
```

Choose option 1 (Bot) and enter your bot token.

#### Bot Limitations

- Only receives messages sent directly to the bot
- Cannot access your personal chats
- Users must start conversation with `/start`
- Cannot see messages in groups unless mentioned

### Method 2: User Account (Full Access)

#### Prerequisites

1. Get API credentials from https://my.telegram.org:
   - Log in with your phone number
   - Go to "API development tools"
   - Create an app (if needed)
   - Copy the **api_id** and **api_hash**

2. For full functionality, you need an MTProto proxy server (advanced)

#### Setup

Run the setup script and choose option 2:
```bash
ruby setup_telegram.rb
```

Provide:
- API ID
- API Hash
- Phone number (with country code)

#### Authentication Process

1. You'll receive a code in your Telegram app
2. Enter the code when prompted
3. If you have 2FA enabled, enter your password
4. Session is saved for future use

### Configuration Options

#### Bot Configuration
```ruby
{
  bot_token: 'YOUR_BOT_TOKEN',
  fetch_limit: 100,
  polling_interval: 60
}
```

#### User Account Configuration
```ruby
{
  api_id: 'YOUR_API_ID',
  api_hash: 'YOUR_API_HASH',
  phone_number: '+1234567890',
  session_string: 'saved_after_auth',
  mtproto_api_url: 'http://localhost:8081'
}
```

### Message Types Supported

- Text messages
- Photos and videos
- Voice messages and audio
- Documents and files
- Stickers and GIFs
- Location sharing
- Contact cards
- Channel posts
- Group messages

## Testing the Sources

After setup, test your sources:

1. In Heathrow, press `s` to view sources
2. Navigate to WhatsApp or Telegram source
3. Press `t` to test connection
4. Check for success message

## Troubleshooting

### WhatsApp Issues

**"API server not running"**
- Ensure the WhatsApp API server is running on port 8080
- Check with: `curl http://localhost:8080/health`

**"Device not authenticated"**
- Re-run the setup script
- Try QR code method if pairing code fails
- Ensure your phone has internet connection

**"No messages fetched"**
- WhatsApp Web must stay connected
- Check phone's internet connection
- Verify in WhatsApp: Settings → Linked Devices

### Telegram Issues

**Bot not receiving messages**
- Users must start conversation with `/start`
- In groups, bot needs to be admin or mentioned
- Check bot token is correct

**User account authentication fails**
- Verify api_id and api_hash are correct
- Phone number must include country code
- Code expires after 5 minutes
- 2FA password is case-sensitive

**"Session expired"**
- Re-run authentication process
- Session strings expire after long inactivity

## Security Notes

### WhatsApp
- Messages are end-to-end encrypted
- Device sessions persist until manually disconnected
- Each device has unique encryption keys
- Disconnect unused devices from WhatsApp settings

### Telegram
- Bot tokens should be kept secret
- API credentials are sensitive - don't share
- Session strings grant full account access
- Use environment variables for credentials in production

## Advanced Configuration

### Running API Servers as Services

#### WhatsApp API Service
Create `/etc/systemd/system/whatsmeow-api.service`:
```ini
[Unit]
Description=WhatsApp API Server
After=network.target

[Service]
Type=simple
User=your-user
WorkingDirectory=/path/to/whatsmeow-api
ExecStart=/usr/bin/go run main.go
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

#### Start the service:
```bash
sudo systemctl enable whatsmeow-api
sudo systemctl start whatsmeow-api
```

### Multiple Accounts

You can add multiple WhatsApp or Telegram sources:
- Use different device_ids for WhatsApp
- Use different bot tokens or phone numbers for Telegram
- Each source syncs independently

### Filtering and Rules

Configure message filtering in Heathrow:
- Create views for specific contacts
- Filter by sender or group
- Set up notifications for important messages

## API Server Requirements

### WhatsApp (whatsmeow)
- Go 1.19 or higher
- SQLite for session storage
- ~50MB RAM per connected device
- Persistent storage for media cache

### Telegram (MTProto)
- Python 3.8+ or Go 1.19+
- Session storage (file or database)
- ~30MB RAM per session
- Optional media download storage

## Rate Limits

### WhatsApp
- No official rate limits for receiving
- Sending limited to prevent spam
- Reconnection backoff on disconnects

### Telegram
- Bot API: 30 messages/second
- MTProto: Adaptive rate limiting
- Respect flood wait errors

## Next Steps

1. Start Heathrow and verify sources appear
2. Monitor initial message sync
3. Configure polling intervals as needed
4. Set up views for different platforms
5. Consider running API servers as background services