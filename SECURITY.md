# Security and responsible use

## Public repository rules

Never commit or publish:

- real tenant, subscription, Workspace, group, application, service principal, or user identifiers;
- real UPNs, email addresses, display names, or company domains;
- sign-in events, generated CSV files, screenshots, or operational logs;
- client secrets, access/refresh tokens, certificate private keys, or passwords;
- internal application names, server paths, ticket numbers, or operating procedures.

The sample values in this repository are synthetic. The `.invalid` domain is intentionally non-resolvable. Local configuration, `output/`, and `logs/` are ignored, but `.gitignore` is only a guardrail: inspect staged changes and commit history before every push.

If sensitive data is committed, do not merely delete it in a later commit. Stop distribution, rotate any exposed credential, follow the organization's incident process, and remove the data from Git history using an approved procedure.

## Least privilege

The interactive script requests delegated read scopes only. Review Graph consent and the executing user's Microsoft Entra role separately; both affect access. Do not replace the documented scopes with broad directory permissions merely to bypass a permissions problem without review.

For hidden-membership groups, additional access may be necessary. Grant it only when the business requirement explicitly includes those groups.

## Output handling

The report contains personal data and employee application-use metadata. Apply:

- access control and need-to-know sharing;
- approved encrypted storage and transport;
- documented retention and deletion periods;
- auditability for automated or repeated execution;
- local and legal privacy requirements.

The cumulative CSV is an operational convenience, not a substitute for a governed audit-log archive.

For Log Analytics-based reports, do not disclose the Workspace ID, subscription,
retention design, table availability, KQL diagnostics, or long-term raw-log
details to a report recipient unless that disclosure is separately approved.
Share the minimal generated CSV rather than query responses or operational logs.

## Internal customization

Keep organization-specific configuration, documentation, destinations, schedules, and runbooks in an approved internal management location. Before company use, require human review of:

- code and dependencies;
- requested permissions and administrator roles;
- application-ID semantics and success criteria;
- CSV recipients, retention, and removal handling;
- error paths and test evidence;
- applicable policy for AI-assisted code.

Do not add unattended authentication by placing a secret in `config.json`. Prefer certificate-based or managed identity approaches where supported, with credentials stored in an approved secret-management system.

## Reporting a vulnerability

For a public portfolio repository, enable GitHub private vulnerability reporting or publish a private security contact. Do not place tenant evidence, production output, or credentials in a public issue.
