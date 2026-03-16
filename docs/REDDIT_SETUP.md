# Reddit Setup Guide for Heathrow

This guide will help you set up Reddit as a source in Heathrow to monitor subreddit posts and optionally your private messages.

## Features

- **Subreddit Posts**: Monitor multiple subreddits for new posts
- **Comments**: Optionally fetch top comments on posts
- **Private Messages**: Read your Reddit inbox (requires authentication)
- **Rich Content**: Handles images, videos, and Reddit galleries
- **Metadata**: Includes post scores, comment counts, and flairs

## Prerequisites

You need a Reddit application to use the Reddit API. If you don't have one, follow the setup below.

## Creating a Reddit Application

### 1. Go to Reddit App Preferences
- Navigate to https://www.reddit.com/prefs/apps
- Log in with your Reddit account

### 2. Create a New App
- Click "Create App" or "Create Another App"
- Fill in:
  - **Name**: Your app name (e.g., "Heathrow Integration")
  - **App type**: Choose "script" for full features or "web app" for read-only
  - **Description**: Brief description
  - **About URL**: (optional)
  - **Redirect URI**: http://localhost:8080 (required but not used)

### 3. Save Your Credentials
- **Client ID**: The short string under your app name
- **Client Secret**: The longer "secret" string

## Quick Setup

Run the setup script:

```bash
ruby setup_reddit_sources.rb
```

This will:
1. Add a Reddit Posts source monitoring r/programming, r/ruby, r/linux, r/vim
2. Optionally set up private messages (requires username/password)

## Manual Setup in Heathrow

1. In Heathrow, press 's' for Sources
2. Press 'a' to add a new source
3. Choose "Reddit"
4. Fill in the configuration:

### For Subreddit Posts:

- **Account Name**: Reddit Posts (or any name you prefer)
- **Client ID**: Your Reddit app's client ID
- **Client Secret**: Your Reddit app's client secret
- **User Agent**: Descriptive string (e.g., "Heathrow/1.0 by /u/yourusername")
- **Mode**: subreddit
- **Subreddits**: Comma-separated list (e.g., "programming,ruby,linux")
- **Fetch Limit**: Posts per subreddit (default: 25)
- **Include Comments**: true/false (fetch top comments)
- **Check Interval**: Seconds between checks (e.g., 300 for 5 minutes)

### For Private Messages:

- **Account Name**: Reddit Messages
- **Client ID**: Your Reddit app's client ID  
- **Client Secret**: Your Reddit app's client secret
- **User Agent**: Descriptive string
- **Mode**: messages
- **Username**: Your Reddit username
- **Password**: Your Reddit password
- **Check Interval**: Seconds between checks (e.g., 180 for 3 minutes)

## Configuration Examples

### Monitor Specific Subreddits
```ruby
{
  mode: 'subreddit',
  subreddits: 'programming,webdev,javascript',
  fetch_limit: 30,
  include_comments: false
}
```

### Monitor with Comments
```ruby
{
  mode: 'subreddit',
  subreddits: 'askreddit',
  fetch_limit: 10,
  include_comments: true  # Fetches top 5 comments per post
}
```

### Private Messages Only
```ruby
{
  mode: 'messages',
  username: 'your_reddit_username',
  password: 'your_reddit_password'
}
```

## Testing the Connection

After adding a Reddit source:
1. Go to Sources view (press 's')
2. Navigate to your Reddit source
3. Press 't' to test the connection
4. You should see "Connected with read-only access" or "Connected as u/username"

## Content Types

The Reddit source handles various content types:

- **Text Posts**: Full self-text content
- **Link Posts**: URL with preview
- **Images**: Direct image links and Reddit-hosted images
- **Galleries**: Multiple images in a single post
- **Videos**: Reddit-hosted videos
- **Comments**: Top comments if enabled

## Troubleshooting

### "401 Unauthorized" Error
- Check your client_id and client_secret
- Ensure they match your Reddit app exactly

### No Messages Appearing
- Reddit API has rate limits - wait a few minutes
- Check subreddit names are spelled correctly
- Try testing the connection with 't' key

### Private Messages Not Working
- Requires "script" app type on Reddit
- Username and password must be correct
- 2FA may need to be temporarily disabled

### Rate Limiting
- Reddit limits API requests to 60 per minute
- Set reasonable polling intervals (minimum 60 seconds)
- Avoid fetching too many posts or comments at once

## Security Notes

- Client credentials are stored locally in Heathrow's database
- For private messages, your Reddit password is stored
- Consider using a dedicated Reddit account for Heathrow
- The app only needs read access for subreddit posts

## Advanced Features

### Filter by Flair
You can modify the source to filter posts by flair - useful for subreddits that use flair for categorization.

### Sort Options
The source fetches "hot" posts by default. Can be modified to fetch "new", "top", or "rising" posts.

### Comment Depth
Currently fetches top 5 comments. Can be adjusted in the source code.

## API Limits

Reddit's API has the following limits:
- 60 requests per minute for OAuth clients
- 100 items maximum per request
- Some endpoints require authentication

The Heathrow Reddit source respects these limits automatically.