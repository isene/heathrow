# Gmail OAuth2 Setup Guide for Heathrow

To use Gmail as a source in Heathrow, you need to set up OAuth2 authentication. This is required because Gmail no longer supports simple username/password authentication for third-party apps.

## Prerequisites

1. **oauth2.py script**: Download from https://github.com/google/gmail-oauth2-tools/blob/master/python/oauth2.py
   - Save it to `~/bin/oauth2.py` (or another location you prefer)
   - Make it executable: `chmod +x ~/bin/oauth2.py`

2. **Python 3**: The oauth2.py script requires Python 3

3. **Safe directory**: Create a directory for your OAuth files (e.g., `~/.heathrow/mail`)
   - This directory will store your credentials and refresh token
   - Make sure it's only readable by you: `chmod 700 ~/.heathrow/mail`

## Setup Steps

### 1. Create a Google Cloud Project

1. Go to https://console.cloud.google.com/
2. Create a new project (e.g., "heathrow-mail")
3. Note the project name for later

### 2. Configure OAuth Consent Screen

1. In the Google Cloud Console, go to "APIs & Services" → "OAuth consent screen"
2. Choose "External" as the user type
3. Fill in the required fields:
   - App name: "Heathrow Mail Fetcher" (or your preference)
   - User support email: Your email address
   - Developer contact: Your email address
4. Click "Save and Continue"
5. Add scope: `https://mail.google.com/`
6. Click "Save and Continue" (skip test users)
7. Click "Back to Dashboard"

### 3. Enable Gmail API

1. Go to "APIs & Services" → "Library"
2. Search for "Gmail API"
3. Click on it and press "Enable"

### 4. Create OAuth2 Credentials

1. Go to "APIs & Services" → "Credentials"
2. Click "+ CREATE CREDENTIALS" → "OAuth client ID"
3. Choose "Web application" as the application type
4. Name it (e.g., "Heathrow OAuth")
5. Under "Authorized redirect URIs", add: `https://oauth2.dance/`
6. Click "Create"
7. Download the JSON file

### 5. Save Credentials

1. Rename the downloaded JSON file to match your email address:
   - Example: `youremail@gmail.com.json`
2. Move it to your safe directory:
   - `mv ~/Downloads/client_secret_*.json ~/.heathrow/mail/youremail@gmail.com.json`

### 6. Generate Refresh Token

1. Run the oauth2.py script with your credentials:
   ```bash
   cd ~/.heathrow/mail
   oauth2.py --generate_oauth2_token \
     --client_id=YOUR_CLIENT_ID \
     --client_secret=YOUR_CLIENT_SECRET \
     --scope=https://mail.google.com/
   ```
   
2. The script will give you a URL - open it in your browser
3. Authorize the application
4. Copy the authorization code from the redirect page
5. Paste it into the terminal
6. The script will output a refresh token

### 7. Save Refresh Token

1. Create a text file with your email name:
   - Example: `youremail@gmail.com.txt`
2. Put ONLY the refresh token in this file (no other text)
3. Save it in your safe directory

## File Structure

After setup, your safe directory should contain:
```
~/.heathrow/mail/
├── youremail@gmail.com.json  # OAuth2 credentials from Google
└── youremail@gmail.com.txt   # Refresh token (single line)
```

## Adding to Heathrow

Now you can add Gmail as a source in Heathrow:

1. Press 's' to go to Sources view
2. Press 'a' to add a new source
3. Choose "Gmail (OAuth2)"
4. Fill in:
   - Account Name: Any name you want
   - Gmail Address: youremail@gmail.com
   - Safe Directory: ~/.heathrow/mail
   - OAuth2 Script: ~/bin/oauth2.py
   - Leave other fields as default

## Troubleshooting

- **"Token retrieval failed"**: Check that both .json and .txt files exist and are named correctly
- **"Authentication failed"**: Your refresh token may have expired - regenerate it
- **No new messages**: Gmail might already be marked as read by another client
- **SSL errors**: Make sure you have the gmail_xoauth gem installed: `gem install gmail_xoauth`

## Security Notes

- Keep your safe directory secure (`chmod 700`)
- Never share your refresh token or credentials JSON
- The refresh token doesn't expire unless you revoke it
- You can revoke access at https://myaccount.google.com/permissions