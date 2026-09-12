# Security

`cleanup-chromes` deletes files and kills processes. That power is bounded on purpose: hardcoded regenerable targets only, default-deny orphan gates, scan output before any destructive action.

- Do not post real scan output in a public issue if it contains usernames, hostnames, or profile paths. Redact `/Users/<name>` to `/Users/x` as the fixtures do.
- Report deletion or process-kill bugs through GitHub private vulnerability reporting. Include the skill version, macOS version, the scan verdict line, and a synthetic reproduction — never a live `delete` log from your machine.
- Supported release: the latest `v1.x` tag.
