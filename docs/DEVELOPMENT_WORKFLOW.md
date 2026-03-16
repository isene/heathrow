# Heathrow Development Workflow

**Goal:** Ensure consistent, safe, and efficient development process.

---

## Table of Contents

1. [Development Environment Setup](#development-environment-setup)
2. [Git Workflow](#git-workflow)
3. [Coding Standards](#coding-standards)
4. [Testing Workflow](#testing-workflow)
5. [Documentation Workflow](#documentation-workflow)
6. [Review Process](#review-process)
7. [Release Process](#release-process)
8. [Troubleshooting](#troubleshooting)

---

## Development Environment Setup

### Prerequisites

```bash
# Ruby 3.0+
ruby --version

# SQLite 3
sqlite3 --version

# Git
git --version

# Optional: w3m for HTML email rendering
w3m -version
```

### Initial Setup

```bash
# Clone repository
git clone https://github.com/yourusername/heathrow.git
cd heathrow

# Install dependencies
gem install sqlite3 minitest rcurses

# Create config directories
mkdir -p ~/.heathrow/{plugins,attachments,backups}

# Initialize database
ruby -Ilib -e "require 'heathrow/database'; Heathrow::Database.new.migrate_to_latest"

# Run tests to verify setup
ruby test/test_all.rb
```

### IDE/Editor Configuration

**VS Code:**

```json
{
  "ruby.format": "rubocop",
  "ruby.lint": {
    "rubocop": true
  },
  "files.associations": {
    "*.rb": "ruby"
  }
}
```

**Vim:**

```vim
" .vimrc
autocmd FileType ruby setlocal expandtab shiftwidth=2 tabstop=2
autocmd FileType ruby setlocal colorcolumn=100
```

---

## Git Workflow

### Branch Strategy

**Main Branches:**
- `main` - Production-ready code
- `develop` - Integration branch for next release

**Supporting Branches:**
- `feature/*` - New features
- `bugfix/*` - Bug fixes
- `hotfix/*` - Emergency production fixes
- `refactor/*` - Code improvements
- `docs/*` - Documentation updates

### Branch Naming

```bash
# Features
git checkout -b feature/gmail-plugin
git checkout -b feature/search-engine

# Bug fixes
git checkout -b bugfix/fix-slack-auth
git checkout -b bugfix/memory-leak-in-ui

# Refactoring
git checkout -b refactor/simplify-filter-engine

# Documentation
git checkout -b docs/update-plugin-guide
```

### Commit Messages

**Format:**

```
<type>(<scope>): <subject>

<body>

<footer>
```

**Types:**
- `feat` - New feature
- `fix` - Bug fix
- `refactor` - Code refactoring
- `docs` - Documentation
- `test` - Test additions/changes
- `chore` - Maintenance tasks

**Examples:**

```bash
# Good
git commit -m "feat(plugins): add Gmail OAuth2 authentication"

git commit -m "fix(ui): prevent crash when terminal too small

Terminal width < 80 caused division by zero in pane calculation.
Added minimum width check and display warning message.

Fixes #123"

git commit -m "refactor(database): extract query builder to separate class

Improves testability and readability of database queries.
No functional changes."

# Bad
git commit -m "fixed stuff"
git commit -m "WIP"
git commit -m "asdfasdf"
```

### Workflow Steps

#### 1. Start New Feature

```bash
# Update develop branch
git checkout develop
git pull origin develop

# Create feature branch
git checkout -b feature/my-feature

# Make changes...

# Commit frequently
git add lib/heathrow/my_feature.rb
git commit -m "feat(my-feature): implement core logic"

# Push to remote
git push -u origin feature/my-feature
```

#### 2. Keep Branch Updated

```bash
# Rebase on develop regularly
git fetch origin
git rebase origin/develop

# Resolve conflicts if any
git add <resolved-files>
git rebase --continue

# Force push (only on feature branches!)
git push --force-with-lease
```

#### 3. Submit Pull Request

```bash
# Ensure all tests pass
ruby test/test_all.rb

# Push final version
git push origin feature/my-feature

# Create PR via GitHub CLI or web interface
gh pr create --base develop --title "Add My Feature" --body "Description..."
```

#### 4. After PR Merged

```bash
# Delete local branch
git checkout develop
git pull origin develop
git branch -d feature/my-feature

# Delete remote branch (if not auto-deleted)
git push origin --delete feature/my-feature
```

### Hotfix Workflow

```bash
# Create hotfix from main
git checkout main
git checkout -b hotfix/critical-bug

# Fix the issue
git commit -m "fix(critical): resolve security vulnerability"

# Merge to main
git checkout main
git merge hotfix/critical-bug
git tag v1.2.3
git push origin main --tags

# Merge to develop
git checkout develop
git merge hotfix/critical-bug
git push origin develop

# Delete hotfix branch
git branch -d hotfix/critical-bug
```

---

## Coding Standards

### Ruby Style Guide

**Follow:** [Ruby Style Guide](https://rubystyle.guide/)

**Key Points:**

1. **Indentation:** 2 spaces, no tabs
2. **Line Length:** 100 characters max
3. **Method Length:** 15 lines max (guideline, not strict)
4. **Class Length:** 200 lines max (consider splitting)
5. **Naming:**
   - Classes: `CamelCase`
   - Methods: `snake_case`
   - Constants: `SCREAMING_SNAKE_CASE`
   - Private methods: prefix with `private`

**Example:**

```ruby
module Heathrow
  class MessageRouter
    MAX_RETRIES = 3

    def initialize(filter_engine, view_manager, db)
      @filter_engine = filter_engine
      @view_manager = view_manager
      @db = db
    end

    def route_message(message)
      validate_message(message)

      views = matching_views(message)
      views.each { |view| add_to_view(message, view) }

      log_routing(message, views)
    end

    private

    def validate_message(message)
      raise ArgumentError, "Message cannot be nil" unless message
      raise ArgumentError, "Message must have sender" unless message.sender
    end

    def matching_views(message)
      @view_manager.all_views.select do |view|
        @filter_engine.matches?(message, view.filters)
      end
    end

    def add_to_view(message, view)
      # Implementation...
    end

    def log_routing(message, views)
      # Implementation...
    end
  end
end
```

### File Organization

```
lib/heathrow/
├── heathrow.rb              # Main entry point
├── version.rb               # Version constant
├── config.rb                # Configuration
├── database.rb              # Database layer
├── event_bus.rb             # Event system
├── logger.rb                # Logging
├── cache.rb                 # Caching
├── message.rb               # Message model
├── message_router.rb        # Message routing
├── view_manager.rb          # View management
├── filter_engine.rb         # Filter evaluation
├── search_engine.rb         # Search
├── plugin_manager.rb        # Plugin management
├── stream_manager.rb        # Real-time streaming
├── plugin/
│   ├── base.rb              # Plugin base class
│   ├── errors.rb            # Plugin errors
│   └── registry.rb          # Plugin registry
├── plugins/
│   ├── gmail.rb
│   ├── slack.rb
│   └── ...
├── ui/
│   ├── application.rb       # Main UI
│   ├── pane_manager.rb      # Pane management
│   ├── input_handler.rb     # Input handling
│   ├── renderer.rb          # Rendering
│   ├── composer.rb          # Message composer
│   └── thread_view.rb       # Thread view
└── migrations/
    ├── 001_initial.rb
    └── ...
```

### Documentation Comments

**Use YARD format:**

```ruby
# Fetch messages from the plugin
#
# @param since [Integer, nil] Unix timestamp to fetch from (nil for all)
# @return [Array<Heathrow::Message>] Array of normalized messages
# @raise [Plugin::ConnectionError] If connection fails
# @raise [Plugin::AuthenticationError] If authentication fails
#
# @example Fetch recent messages
#   messages = plugin.fetch_messages(since: Time.now.to_i - 3600)
#
def fetch_messages(since: nil)
  # Implementation...
end
```

---

## Testing Workflow

### Running Tests

```bash
# Run all tests
ruby test/test_all.rb

# Run specific test file
ruby test/test_filter_engine.rb

# Run specific test
ruby test/test_filter_engine.rb -n test_simple_equality_filter

# Run with verbose output
ruby test/test_all.rb -v

# Run with code coverage (if using SimpleCov)
COVERAGE=1 ruby test/test_all.rb
```

### Writing Tests

**Test File Naming:**
- Unit tests: `test/test_<component>.rb`
- Integration tests: `test/integration/test_<feature>.rb`
- E2E tests: `test/e2e/test_<workflow>.rb`

**Test Structure:**

```ruby
require 'minitest/autorun'
require_relative 'test_helper'

class TestMessageRouter < Minitest::Test
  # Setup runs before each test
  def setup
    @db = Database.new(":memory:")
    @filter_engine = FilterEngine.new
    @view_manager = ViewManager.new(@db, @filter_engine)
    @router = MessageRouter.new(@filter_engine, @view_manager, @db)
  end

  # Teardown runs after each test (optional)
  def teardown
    @db.close
  end

  # Test methods must start with "test_"
  def test_routes_message_to_matching_view
    # Arrange
    view = @view_manager.create_view("Test", {field: "sender", op: "=", value: "test@example.com"})
    message = create_test_message(sender: "test@example.com")

    # Act
    @router.route_message(message)

    # Assert
    messages = @router.messages_for_view(view.id)
    assert_equal 1, messages.count
    assert_equal message.external_id, messages.first.external_id
  end

  def test_raises_error_on_invalid_message
    assert_raises(ArgumentError) do
      @router.route_message(nil)
    end
  end

  private

  def create_test_message(overrides = {})
    TestHelper.create_test_message(overrides)
  end
end
```

### Test Coverage Goals

| Component Type    | Target Coverage |
|-------------------|-----------------|
| Core Layer        | 95%+            |
| Application Layer | 85%+            |
| UI Layer          | 60%+            |
| Plugins           | 75%+            |
| Overall           | 80%+            |

### Continuous Integration

**GitHub Actions Workflow:**

```yaml
# .github/workflows/test.yml
name: Test

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v2

      - name: Set up Ruby
        uses: ruby/setup-ruby@v1
        with:
          ruby-version: 3.2

      - name: Install dependencies
        run: gem install sqlite3 minitest rcurses

      - name: Run tests
        run: ruby test/test_all.rb

      - name: Run rubocop
        run: gem install rubocop && rubocop

      - name: Check coverage
        run: |
          COVERAGE=1 ruby test/test_all.rb
          # Fail if coverage < 80%
```

---

## Documentation Workflow

### Documentation Types

1. **Code Comments** - YARD format for methods/classes
2. **README.md** - Project overview and quickstart
3. **docs/** - Detailed guides
4. **CHANGELOG.md** - Version history
5. **API.md** - API reference (auto-generated from YARD)

### Documentation Standards

**Keep documentation:**
- Up-to-date with code
- Clear and concise
- Example-driven
- Beginner-friendly

**Update documentation when:**
- Adding new feature
- Changing API
- Fixing bug that affects usage
- Deprecating functionality

### Generating API Docs

```bash
# Install YARD
gem install yard

# Generate docs
yard doc

# View docs
yard server
# Open http://localhost:8808
```

---

## Review Process

### Pre-Review Checklist

Before submitting PR, verify:

- [ ] All tests pass
- [ ] No rubocop violations
- [ ] Documentation updated
- [ ] CHANGELOG.md updated
- [ ] Commit messages follow convention
- [ ] No commented-out code
- [ ] No debug print statements
- [ ] Branch rebased on latest develop

### Code Review Guidelines

**For Reviewers:**

1. **Functionality** - Does it work as intended?
2. **Tests** - Are there sufficient tests?
3. **Readability** - Is the code clear?
4. **Performance** - Are there obvious bottlenecks?
5. **Security** - Any vulnerabilities?
6. **Architecture** - Does it fit the design?

**Review Comments:**

```
# Good
"Consider extracting this to a separate method for better testability."
"This could cause a race condition if called from multiple threads."
"Nice solution! One suggestion: use `find` instead of `select.first` for clarity."

# Bad
"This is wrong."
"Why did you do it this way?"
"Just rewrite this."
```

**Approval Criteria:**
- At least 1 approval from maintainer
- All CI checks pass
- No unresolved discussions

---

## Release Process

### Versioning

**Semantic Versioning:** `MAJOR.MINOR.PATCH`

- `MAJOR` - Breaking changes
- `MINOR` - New features (backward compatible)
- `PATCH` - Bug fixes

**Examples:**
- `1.0.0` - Initial stable release
- `1.1.0` - Added Slack plugin
- `1.1.1` - Fixed Slack authentication bug
- `2.0.0` - Changed config file format (breaking)

### Release Steps

#### 1. Prepare Release

```bash
# Create release branch
git checkout develop
git checkout -b release/v1.2.0

# Update version
# Edit lib/heathrow/version.rb
module Heathrow
  VERSION = "1.2.0"
end

# Update CHANGELOG.md
# Add release notes under "## [1.2.0] - 2024-01-15"

# Commit changes
git commit -am "chore: prepare v1.2.0 release"
```

#### 2. Test Release

```bash
# Run full test suite
ruby test/test_all.rb

# Manual testing
./bin/heathrow

# Integration testing with real services (if possible)
```

#### 3. Merge and Tag

```bash
# Merge to main
git checkout main
git merge release/v1.2.0

# Tag release
git tag -a v1.2.0 -m "Release v1.2.0"
git push origin main --tags

# Merge to develop
git checkout develop
git merge release/v1.2.0
git push origin develop

# Delete release branch
git branch -d release/v1.2.0
```

#### 4. Publish

```bash
# Build gem
gem build heathrow.gemspec

# Publish to RubyGems
gem push heathrow-1.2.0.gem

# Create GitHub release
gh release create v1.2.0 --title "v1.2.0" --notes "See CHANGELOG.md"
```

#### 5. Announce

- Post to project blog/website
- Update documentation site
- Notify users (mailing list, Discord, etc.)

### CHANGELOG Format

```markdown
# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Feature X that does Y

### Changed
- Improved performance of Z

### Fixed
- Bug in A that caused B

## [1.2.0] - 2024-01-15

### Added
- Gmail plugin with OAuth2 support
- Full-text search across all messages
- Message threading support

### Changed
- Improved UI rendering performance by 50%
- Updated dependencies to latest versions

### Fixed
- Crash when terminal width < 80
- Memory leak in real-time stream manager

### Security
- Fixed XSS vulnerability in HTML email rendering

## [1.1.0] - 2023-12-01

...
```

---

## Troubleshooting

### Common Issues

#### Tests Failing Locally

```bash
# Ensure clean database
rm ~/.heathrow/heathrow.db
ruby -Ilib -e "require 'heathrow/database'; Heathrow::Database.new.migrate_to_latest"

# Clear cache
rm -rf /tmp/heathrow_test_*

# Reinstall dependencies
gem uninstall sqlite3 minitest rcurses
gem install sqlite3 minitest rcurses

# Run tests again
ruby test/test_all.rb
```

#### Rubocop Violations

```bash
# Auto-fix simple violations
rubocop -a

# Auto-fix unsafe violations (be careful!)
rubocop -A

# Ignore specific violations (last resort)
# Add to .rubocop.yml:
# Style/StringLiterals:
#   Enabled: false
```

#### Git Conflicts

```bash
# Abort rebase and start fresh
git rebase --abort
git fetch origin
git rebase origin/develop

# Use merge instead (not recommended)
git merge origin/develop

# Resolve conflicts manually
# Edit conflicted files
git add <resolved-files>
git rebase --continue
```

#### Performance Issues

```bash
# Profile code
ruby -r profile test/test_all.rb

# Memory profiling
gem install memory_profiler
ruby -r memory_profiler -e "MemoryProfiler.report { require 'heathrow' }.pretty_print"

# Database performance
# Add logging to database.rb
def query(sql, params = [])
  start = Time.now
  result = @db.execute(sql, params)
  puts "Query took #{Time.now - start}s: #{sql}"
  result
end
```

### Getting Help

1. **Check documentation:** `docs/`
2. **Search issues:** GitHub issues
3. **Ask in discussions:** GitHub discussions
4. **IRC/Discord:** Project chat
5. **Email:** maintainers

---

## Development Tips

### Productivity

1. **Use aliases:**

```bash
# .bashrc or .zshrc
alias ht='./bin/heathrow'
alias htt='ruby test/test_all.rb'
alias htl='tail -f ~/.heathrow/heathrow.log'
```

2. **Quick iterations:**

```bash
# Watch files and auto-run tests
gem install watchr
# Create Watchfile with test runner
```

3. **Debugging:**

```ruby
# Use pry for debugging
gem install pry
# In code:
require 'pry'
binding.pry
```

### Best Practices

1. **Test-driven development** - Write test first, then implementation
2. **Commit often** - Small commits are easier to review and revert
3. **Document as you go** - Don't leave it for later
4. **Ask for help early** - Don't waste time stuck
5. **Review your own code** - Read diff before committing

### Code Review Checklist

Before submitting PR:

```markdown
## PR Checklist

- [ ] Tests pass locally
- [ ] Added tests for new functionality
- [ ] Updated documentation
- [ ] Updated CHANGELOG.md
- [ ] No rubocop violations
- [ ] No breaking changes (or clearly documented)
- [ ] Reviewed my own code in diff view
- [ ] Tested manually in terminal
- [ ] Considered edge cases
- [ ] Checked for security issues
- [ ] Ensured backward compatibility
```

---

This workflow ensures consistent, high-quality development across the entire Heathrow project.
