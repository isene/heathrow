# Heathrow Documentation

Welcome to Heathrow documentation! This directory contains comprehensive guides for understanding, developing, and contributing to Heathrow.

---

## Quick Navigation

### For Users

- **Getting Started** - (Coming in Phase 6: Polish & Distribution)
- **User Manual** - (Coming in Phase 6: Polish & Distribution)
- **Configuration Guide** - (Coming in Phase 1: Email Mastery)

### For Developers

- **[PROJECT_PLAN.md](PROJECT_PLAN.md)** - Complete implementation roadmap
- **[ARCHITECTURE.md](ARCHITECTURE.md)** - System design and component isolation
- **[DATABASE_SCHEMA.md](DATABASE_SCHEMA.md)** - Complete database structure
- **[PLUGIN_SYSTEM.md](PLUGIN_SYSTEM.md)** - How to create plugins
- **[DEVELOPMENT_WORKFLOW.md](DEVELOPMENT_WORKFLOW.md)** - Git, testing, and releases

### For Contributors

- **CONTRIBUTING.md** - (Coming soon)
- **CODE_OF_CONDUCT.md** - (Coming soon)

---

## Documentation Overview

### PROJECT_PLAN.md

**What:** The master implementation plan for Heathrow

**Covers:**
- Complete roadmap from current state to 1.0 release
- 6 phases of development (Foundation → Polish)
- Detailed breakdown of each feature
- Timeline estimates (aggressive, realistic, MVP)
- Success criteria for each phase

**Read this if you want to:**
- Understand the project vision
- See what features are planned
- Know when features will be delivered
- Understand project priorities

---

### ARCHITECTURE.md

**What:** The technical architecture and system design

**Covers:**
- Layer architecture (UI → Application → Core → Plugins)
- Component isolation strategies
- Data flow diagrams
- Concurrency model
- Error handling strategy
- Testing strategy
- Performance considerations

**Read this if you want to:**
- Understand how Heathrow is structured
- Know which components can fail independently
- See how messages flow through the system
- Understand threading and concurrency
- Know performance targets and budgets

---

### DATABASE_SCHEMA.md

**What:** Complete database structure and design

**Covers:**
- All table schemas with column definitions
- Index strategies for performance
- Full-text search implementation
- Migration system
- Encryption strategy
- Backup and recovery
- Sample data and queries

**Read this if you want to:**
- Understand data storage
- Query the database directly
- Create database migrations
- Optimize database performance
- Understand security measures

---

### PLUGIN_SYSTEM.md

**What:** How plugins work and how to create them

**Covers:**
- Plugin architecture and isolation
- Plugin lifecycle (load → start → run → stop → unload)
- Plugin interface (Base class API)
- Plugin discovery and registration
- Error handling and recovery
- Example plugins (Gmail, RSS, Slack)
- Step-by-step plugin development guide
- Testing plugins
- Publishing community plugins

**Read this if you want to:**
- Create a new plugin for a service
- Understand how plugins are isolated
- Debug plugin issues
- Publish a plugin to the community
- Understand plugin capabilities

---

### DEVELOPMENT_WORKFLOW.md

**What:** How to contribute to Heathrow

**Covers:**
- Development environment setup
- Git workflow and branching strategy
- Commit message conventions
- Coding standards and style guide
- Testing workflow and coverage goals
- Documentation standards
- Code review process
- Release process
- Troubleshooting common issues

**Read this if you want to:**
- Contribute code to Heathrow
- Understand the development process
- Set up your development environment
- Know coding standards
- Understand the release process
- Get your PR merged

---

## Document Relationships

```
PROJECT_PLAN.md ──┐
                  │
                  ├──→ ARCHITECTURE.md ──┐
                  │                      │
                  │                      ├──→ DATABASE_SCHEMA.md
                  │                      │
                  └──→ PLUGIN_SYSTEM.md ─┤
                                         │
                                         └──→ DEVELOPMENT_WORKFLOW.md
```

**Flow:**
1. **PROJECT_PLAN.md** - What are we building?
2. **ARCHITECTURE.md** - How is it structured?
3. **DATABASE_SCHEMA.md** - How is data stored?
4. **PLUGIN_SYSTEM.md** - How do integrations work?
5. **DEVELOPMENT_WORKFLOW.md** - How do I contribute?

---

## Key Concepts

### Airport Metaphor

Heathrow is named after the major international airport. This metaphor runs throughout:

- **Hub** - Central connection point for all communications
- **Terminals** - Different platforms (Gmail, Slack, Discord, etc.)
- **Gates** - Individual channels within platforms
- **Arrivals** - Incoming messages
- **Departures** - Outgoing messages
- **Transit** - Forwarding messages between platforms
- **Lounge** - Read/archived messages

### LEGO Architecture

Every component is a self-contained LEGO piece:

- **Modularity** - Each piece has one clear purpose
- **Isolation** - Breaking one piece doesn't break others
- **Interfaces** - Clear connection points between pieces
- **Testability** - Each piece can be tested independently
- **Replaceability** - Can swap out pieces without rewriting

### Plugin Isolation

Plugins are completely isolated:

- **No shared state** - Plugins can't access each other
- **Independent failure** - Plugin crash doesn't affect core
- **Hot reload** - Can load/unload without restart
- **Clear API** - Plugins only access core via Base class
- **Error boundaries** - Exceptions caught and logged

### Layer Separation

```
UI Layer ────────────→ User sees and interacts
     │
     ▼
Application Layer ───→ Business logic and routing
     │
     ▼
Core Layer ──────────→ Infrastructure (DB, events, config)
     │
     ▼
Plugin Layer ────────→ External service integrations
```

Each layer:
- Only talks to adjacent layers
- Has well-defined interfaces
- Can fail independently (except Core)
- Can be tested in isolation

---

## Development Phases

### Phase 0: Foundation (Current)

**Goal:** Unbreakable core for all future features

- [x] Project planning
- [x] Architecture design
- [x] Database schema
- [x] Plugin system design
- [ ] Rename Heathrow → Heathrow
- [ ] Core component implementation
- [ ] Plugin manager
- [ ] Testing framework

### Phase 1: Email Mastery

**Goal:** Replace mutt

- Gmail plugin (OAuth2)
- Generic IMAP/SMTP
- Thread view
- HTML rendering
- Attachments
- Search

### Phase 2: Chat Platforms

**Goal:** Replace weechat

- Slack
- Discord
- Telegram
- IRC
- Real-time streaming

### Phase 3: Social & News

**Goal:** Replace newsboat and reddit clients

- RSS/Atom feeds
- Reddit integration
- Mastodon
- Hacker News

### Phase 4: Proprietary Messengers

**Goal:** Bridge to closed ecosystems

- WhatsApp
- Facebook Messenger
- Signal (if possible)

### Phase 5: Advanced Features

**Goal:** Beyond replacement - innovation

- Unified search
- Smart filters
- Automation/scripting
- Notifications

### Phase 6: Polish & Distribution

**Goal:** Production-ready for mass adoption

- Installation wizard
- Migration tools
- Documentation
- Package distribution

---

## Timeline

### Minimum Viable Product

- Phase 0: Foundation
- Phase 1: Email only (Gmail + IMAP)
- Phase 2: Slack + Discord only

### Realistic Release

- All 6 phases complete
- Full testing
- Complete documentation
- Community feedback incorporated

### Aggressive

- All 6 phases complete
- Minimal testing
- Basic documentation
- **Not recommended** - quality over speed

---

## Contributing

### How to Get Started

1. Read **PROJECT_PLAN.md** to understand the vision
2. Read **ARCHITECTURE.md** to understand the structure
3. Read **DEVELOPMENT_WORKFLOW.md** to set up your environment
4. Pick an issue labeled "good first issue"
5. Submit a PR following the workflow

### Where to Contribute

**Code:**
- Core components (Foundation phase)
- New plugins (any platform)
- UI improvements
- Test coverage

**Documentation:**
- User guides
- API documentation
- Tutorials
- Examples

**Testing:**
- Manual testing
- Bug reports
- Performance testing
- Security review

**Community:**
- Answer questions
- Review PRs
- Write blog posts
- Create videos

---

## Getting Help

### Resources

- **GitHub Issues** - Bug reports and feature requests
- **GitHub Discussions** - Questions and ideas
- **IRC** - `#heathrow` on Libera.Chat (coming soon)
- **Discord** - Heathrow community server (coming soon)

### FAQs

**Q: When will Heathrow be ready for daily use?**

A: We're targeting MVP (email + basic chat) soon, with full 1.0 following. Watch the repo for updates!

**Q: Can I use Heathrow now?**

A: Not yet. We're in Phase 0 (Foundation). Stay tuned!

**Q: How can I help?**

A: See CONTRIBUTING.md (coming soon). For now, star the repo and spread the word!

**Q: Will Heathrow support platform X?**

A: If it can be integrated via plugin, yes! See PLUGIN_SYSTEM.md for how to create one.

**Q: Why terminal/CLI only?**

A: Focus and simplicity. Power users love the terminal. Web/GUI could come later as separate projects.

**Q: Is this production-ready?**

A: No. Currently in early development (Phase 0). Do not use for critical communications yet.

---

## License

MIT License - See LICENSE file

---

## Credits

**Inspired by:**
- mutt - Email client that taught us email can be beautiful in the terminal
- weechat - IRC client with perfect UX
- newsboat - RSS reader with clean design
- RTFM - The perfect rcurses reference implementation

**Built with:**
- Ruby - Beautiful, expressive language
- SQLite - Reliable, embedded database
- rcurses - Terminal UI library

---

**Welcome to Heathrow - Where all your messages connect!**
