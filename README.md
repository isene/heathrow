# Heathrow

<img src="img/heathrow.svg" align="right" width="150">

**Where all your messages connect.**

![Ruby](https://img.shields.io/badge/language-Ruby-red) [![Gem Version](https://badge.fury.io/rb/heathrow.svg)](https://badge.fury.io/rb/heathrow) ![Unlicense](https://img.shields.io/badge/license-Unlicense-green) [![Documentation](https://img.shields.io/badge/docs-comprehensive-blue)](docs/) ![Stay Amazing](https://img.shields.io/badge/Stay-Amazing-important)

A unified TUI for all your communication. Like Heathrow Airport, every message routes through one hub. Email, chat, RSS, forums, and more in a single terminal interface.

## Features

- **Unified Message View**: All your messages from different sources in one place
- **Multiple Views**: Switch between All Messages, New Messages, and 10 customizable filtered views
- **Smart Filtering**: Create custom views based on source, sender, keywords, date ranges
- **Color Coding**: Messages color-coded by source with unread highlighting
- **RTFM-style Interface**: Familiar and efficient pane-based layout
- **Real-time Updates**: Background polling service for new messages
- **Reply Capability**: Reply to messages directly from Heathrow (for supported sources)
- **Keyboard Navigation**: Full keyboard control with vim-style keybindings
- **Plugin Architecture**: Extensible system for adding new communication sources

## Installation

### Prerequisites

1. Ruby 2.7 or higher
2. rcurses gem
3. sqlite3 gem

### Install from Source

```bash
# Clone the repository
git clone https://github.com/yourusername/heathrow.git
cd heathrow

# Install required gems (simple, no bundler needed!)
gem install rcurses sqlite3

# Or use the install script
./install.sh

# Set up test data (optional)
ruby setup_test_data.rb

# Run Heathrow
./bin/heathrow
```

### Install as Gem (coming soon)

```bash
gem install heathrow
```

## Quick Start

1. **Launch Heathrow**:
   ```bash
   heathrow
   ```

2. **Set up your first source** (Press `S` then `a`):
   - Choose source type (email, WhatsApp, Discord, etc.)
   - Follow the setup wizard
   - Configure polling interval

3. **Navigate messages**:
   - `j`/`k` or arrow keys to move up/down
   - `Enter` to read message
   - `Space` to mark as read/unread
   - `*` to star/unstar

## Key Bindings

### Navigation
| Key | Action |
|-----|--------|
| `j`/`↓` | Move down in message list |
| `k`/`↑` | Move up in message list |
| `h`/`←` | Go back / parent view |
| `l`/`→`/`Enter` | Open message |
| `PgDn` | Page down |
| `PgUp` | Page up |
| `Home` | Go to first message |
| `End` | Go to last message |

### Views
| Key | Action |
|-----|--------|
| `A` | All messages |
| `N` | New (unread) messages |
| `S` | Sources configuration |
| `0`-`9` | Custom filtered views |
| `F` | Edit filter for current view |

### Message Actions
| Key | Action |
|-----|--------|
| `Space` | Toggle read/unread |
| `*` | Toggle star |
| `r` | Reply to message |
| `R` | Reply all |
| `d` | Delete message |

### UI Controls
| Key | Action |
|-----|--------|
| `w` | Change left pane width (20%-60%) |
| `B` | Cycle border style |
| `-` | Toggle preview pane |
| `?` | Show help |
| `q` | Quit Heathrow |

## Configuration

Configuration files are stored in `~/.heathrow/`:

```
~/.heathrow/
├── heathrow.db         # SQLite database for messages
├── config.yml       # Main configuration
├── sources/         # Source configurations
│   ├── email.yml
│   ├── whatsapp.yml
│   └── ...
├── views/           # Custom view filters
│   ├── view_1.yml
│   ├── view_2.yml
│   └── ...
├── attachments/     # Message attachments
├── plugins/         # Custom plugins
└── logs/           # Application logs
```

### Example View Configuration

Create a view to show only messages from your family:

```yaml
# ~/.heathrow/views/view_2.yml
name: "Family"
filters:
  sender_pattern: "(John|Jane|Mom|Dad)"
  source_types: ["whatsapp", "messenger", "email"]
sort_order: "timestamp DESC"
color_scheme:
  foreground: 226  # Yellow
  background: 0     # Default
```

## Supported Sources

### Currently Implemented
- [ ] Email (IMAP/POP3)
- [ ] RSS Feeds
- [ ] Web Page Monitoring

### In Development
- [ ] WhatsApp (via WhatsApp Web API)
- [ ] Discord
- [ ] Telegram
- [ ] Reddit (messages & watched forums)
- [ ] Slack
- [ ] IRC
- [ ] LinkedIn Messages
- [ ] Facebook Messenger

## Plugin Development

Create custom plugins for new sources:

```ruby
# ~/.heathrow/plugins/my_source.rb
module Heathrow
  class MySourcePlugin < Plugin
    def fetch_messages
      # Fetch and return array of messages
      messages = []
      
      # Your API/scraping logic here
      
      messages.map do |raw_msg|
        {
          external_id: raw_msg[:id],
          sender: raw_msg[:from],
          subject: raw_msg[:title],
          content: raw_msg[:body],
          timestamp: raw_msg[:date],
          attachments: raw_msg[:files]
        }
      end
    end
    
    def can_reply?
      true  # If this source supports replies
    end
    
    def send_message(recipient, content)
      # Send reply logic
    end
  end
end

# Register the plugin
Heathrow::PluginManager.register('mysource', MySourcePlugin)
```

## Architecture

Heathrow uses a modular architecture:

- **SQLite Database**: Stores message metadata and content
- **Plugin System**: Each source type is a plugin
- **Background Poller**: Fetches new messages at configured intervals
- **TUI Interface**: Built on rcurses for efficient terminal rendering
- **View System**: Flexible filtering and custom views

## Development

### Running Tests
```bash
bundle exec rspec
```

### Building Gem
```bash
gem build heathrow.gemspec
```

### Contributing
1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## Roadmap

- [x] Core TUI interface with RTFM layout
- [x] SQLite database for message storage
- [x] Basic navigation and view switching
- [x] Plugin architecture
- [ ] Email plugin (IMAP/POP3)
- [ ] WhatsApp plugin
- [ ] Discord plugin
- [ ] RSS feed plugin
- [ ] Reply functionality
- [ ] Search and filtering
- [ ] Notification system
- [ ] Encrypted storage option
- [ ] Export/backup functionality
- [ ] Themes and customization

## Credits

- Created by Geir Isene with Claude Code
- Built on [rcurses](https://github.com/isene/rcurses)
- Inspired by [RTFM](https://github.com/isene/RTFM) file manager

## License

Public Domain - No rights reserved

This software is released into the public domain. Anyone is free to copy, modify, publish, use, compile, sell, or distribute this software, either in source code form or as a compiled binary, for any purpose, commercial or non-commercial, and by any means.

## Support

- GitHub Issues: [github.com/yourusername/heathrow/issues](https://github.com/yourusername/heathrow/issues)
- Documentation: [github.com/yourusername/heathrow/wiki](https://github.com/yourusername/heathrow/wiki)

---

*Heathrow - Bringing all your communications together in the terminal*