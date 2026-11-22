# Reporting a security or privacy issue

Email **support@binjamshid.com** privately with the subject **Masoon security report**. Include the app version or commit, platform and OS, the affected feature, a short description of the impact, and a way to reach you. For a fork, alert the fork maintainer too if the behavior is specific to that fork. The current upstream code and official builds are the starting points for triage. Include older affected versions if known.

Use only accounts and local data you control. A synthetic report such as “two sample learners on my local test server could see the same test plan after changing accounts” is enough to start triage. Omit real learner names, email addresses, supervision records, account codes, payment receipts, backups, voice recordings, private keys and unredacted logs. If additional evidence is needed, agree on a private transfer method first.

The maintainer will assess affected versions, coordinate a fix with affected maintainers or operators, and agree on disclosure timing where possible. Keep reports and remediation details private during triage. The public issue tracker is for ordinary software bugs and content corrections.

## Publishing a security fix to covered source

[License section 4](LICENSE) permits a delay when publication would disclose an unremediated vulnerability. Promptly notify the affected maintainer privately. The delay runs until the earlier of first public disclosure or 90 calendar days after making the fix, with the ordinary deadline applying if it would expire later. You may privately share the fix with affected maintainers or operators for remediation during the delay. The exception applies only to the security fix.

## Data in development

Use the supplied fictional examples or data you created yourself. Keep account records, backups, diagnostic files, receipts and recordings out of issue reports and pull requests. The local examples in this repository require no access to a production account or server.
