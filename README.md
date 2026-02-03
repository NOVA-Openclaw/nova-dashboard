# NOVA Dashboard

A lightweight, real-time status dashboard for AI agents running on [Clawdbot](https://github.com/clawdbot/clawdbot).

![Dashboard Screenshot](screenshot.png)

## Features

- **Agent Status**: Context window usage, compaction count, model info
- **Anthropic API Costs**: Daily spend, monthly projections, budget alerts
- **System Stats**: CPU, memory, disk, load average
- **Auto-refresh**: Updates every 30 seconds
- **Mobile-friendly**: Responsive design

## Setup

1. Clone this repo to your web server directory:
   ```bash
   git clone https://github.com/nova-atlas/nova-dashboard.git /var/www/dashboard
   ```

2. Copy example configs and customize:
   ```bash
   cp status.example.json status.json
   cp anthropic.example.json anthropic.json
   cp system.example.json system.json
   ```

3. Set up cron jobs to update the JSON files (see [Scripts](#scripts))

4. (Optional) Add basic auth via `.htaccess` and `.htpasswd`

## JSON Data Sources

The dashboard reads from three JSON files that you populate via scripts:

| File | Description | Update Frequency |
|------|-------------|------------------|
| `status.json` | Agent context/session info | Every 5 min |
| `anthropic.json` | API cost tracking | Every 15 min |
| `system.json` | Server metrics | Every 5 min |

## Scripts

Example update scripts for Clawdbot users:

### Agent Status (`status.json`)
Use `session_status` tool output to populate context usage.

### Anthropic Costs (`anthropic.json`)
Use the [Anthropic Admin API](https://docs.anthropic.com/en/api/administration-api) cost_report endpoint.

**Note**: API amounts are returned in **cents** — divide by 100 for dollars!

### System Stats (`system.json`)
Simple bash script using `top`, `df`, `uptime`.

## Customization

- Replace `avatar.png` with your agent's avatar
- Replace `favicon.png` with your preferred icon
- Edit CSS variables in `index.html` for theming

## Security

⚠️ **Never commit credentials!** The `.gitignore` excludes:
- `.htpasswd` (basic auth credentials)
- `.htaccess` (server config)
- Runtime JSON files (may contain sensitive data)

## License

MIT License — use freely, attribution appreciated.

## Credits

Created by [NOVA](https://nova.dustintrammell.com) ✨

Built for use with [Clawdbot](https://clawdbot.com) by [Trammell Ventures](https://trammellventures.com).
