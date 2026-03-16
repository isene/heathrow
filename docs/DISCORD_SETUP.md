# Discord Setup Guide for Heathrow

This guide will help you set up Discord as a source in Heathrow to monitor Discord channels and servers.

## Prerequisites

You need a Discord Bot Token. If you already have one (like from discord-irc), you can use it. Otherwise, follow the setup below.

## Creating a Discord Bot

### 1. Create a Discord Application

1. Go to https://discord.com/developers/applications
2. Click "New Application"
3. Give it a name (e.g., "Heathrow Bot")
4. Click "Create"

### 2. Create the Bot

1. In your application, go to the "Bot" section in the left sidebar
2. Click "Add Bot"
3. Under "Token", click "Copy" to copy your bot token
4. **Save this token securely** - you'll need it for Heathrow

### 3. Set Bot Permissions

1. In the "Bot" section, configure:
   - **Public Bot**: OFF (unless you want others to add your bot)
   - **Requires OAuth2 Code Grant**: OFF
   - **Message Content Intent**: ON (required to read message content)

### 4. Invite Bot to Your Servers

1. Go to "OAuth2" → "URL Generator" in the left sidebar
2. Under "Scopes", select:
   - `bot`
3. Under "Bot Permissions", select:
   - Read Messages/View Channels
   - Read Message History
4. Copy the generated URL
5. Open the URL in your browser
6. Select the server you want to add the bot to
7. Click "Authorize"

## Getting Channel and Server IDs

### Enable Developer Mode

1. Open Discord (app or web)
2. Go to Settings → Advanced
3. Enable "Developer Mode"

### Get Channel IDs

1. Right-click on any channel
2. Click "Copy Channel ID"

### Get Server/Guild IDs

1. Right-click on any server icon
2. Click "Copy Server ID"

## Adding Discord to Heathrow

1. In Heathrow, press 's' for Sources view
2. Press 'a' to add a new source
3. Choose "Discord"
4. Fill in:
   - **Account Name**: Any name you want (e.g., "My Discord")
   - **Bot Token**: Your bot token (starts with MTM...)
   - **Is Bot Token?**: Yes (leave checked)
   - **Channel IDs**: Comma-separated list of channel IDs to monitor
     - Example: `123456789012345678,234567890123456789`
   - **Guild/Server IDs**: Optional - monitors all channels in these servers
   - **Messages per fetch**: 20 (or adjust as needed)
   - **Check interval**: 60 seconds (or adjust as needed)

## Configuration Examples

### Monitor Specific Channels Only
```
Channel IDs: 123456789012345678,234567890123456789
Guild IDs: (leave empty)
```

### Monitor All Channels in a Server
```
Channel IDs: (leave empty)
Guild IDs: 345678901234567890
```

### Monitor Mix of Both
```
Channel IDs: 123456789012345678
Guild IDs: 456789012345678901
```

## Using an Existing discord-irc Bot

If you already have discord-irc running (like in your weechat setup), you can reuse the same bot token:

1. Find your discord-irc config (usually `~/.config/discord-irc.json`)
2. Copy the `discordToken` value
3. Note the channel IDs from `channelMapping`
4. Use these in Heathrow

## Troubleshooting

### "403 Forbidden" Errors
- The bot doesn't have permission to read that channel
- Re-invite the bot with proper permissions
- Check if the channel is private and the bot has access

### No Messages Appearing
- Check the bot has "Read Message History" permission
- Verify the channel IDs are correct
- Ensure the bot is actually in the server

### "401 Unauthorized"
- Your bot token is invalid or expired
- Double-check you copied the complete token
- Regenerate the token if needed

## Security Notes

- **Never share your bot token** - anyone with it can control your bot
- Bot tokens don't expire unless you regenerate them
- Consider using a separate bot for Heathrow if you use Discord bots elsewhere
- The bot can only see channels it has access to

## Rate Limits

Discord has rate limits to prevent abuse:
- Don't set polling interval below 30 seconds
- The integration fetches max 100 messages per channel per request
- If you hit rate limits, you'll see 429 errors - increase the polling interval

## Privacy Considerations

- The bot can see all messages in channels it has access to
- Messages are stored locally in Heathrow's database
- Consider informing server members if monitoring shared servers