# Group app last sign-in from Log Analytics

## Purpose

This tool creates a minimal, shareable report for the operational question:

> For the users who currently belong to this Entra group, what is the latest successful sign-in for this application that exists in the selected Log Analytics period?

The Workspace and its long-term logs remain under IT control. The output intentionally excludes raw-event and internal Workspace details.

## Data flow

1. Validate JSON before authentication.
2. Reuse or establish an interactive Azure context.
3. Reuse or establish a Microsoft Graph context with read-only delegated scopes.
4. Get direct or transitive group members, cast to `microsoft.graph.user`.
5. Split stable user object IDs into configurable batches.
6. Render KQL from a repository template using only validated GUIDs, UTC timestamps, and allow-listed table names.
7. Query `SigninLogs`, and optionally `AADNonInteractiveUserSignInLogs`, separately.
8. Aggregate `max(TimeGenerated)` by `UserId` inside the Workspace.
9. Preserve the interactive and non-interactive timestamps and calculate the later result.
10. Classify each user as both, interactive only, non-interactive only, or no record.
11. Join with the current Graph member list and output every member with Japanese companion fields.
12. Write the CSV through a temporary file and create a metadata-only operational log.

The query returns only `UserId` and `LastSignInDateTime`. IP address, device, location, user agent, Conditional Access, correlation identifiers, and raw status details do not leave Log Analytics through this tool.

## Why UserId is the join key

UPNs and display names can change. Both supported sign-in tables expose `UserId`, and Graph returns the same Entra user object ID. The report uses current Graph values for UPN and display name while using the stable ID for matching.

Rows with missing or malformed user IDs are not used as evidence. Deleted users that are no longer current group members are not included because this is a current-membership report.

## Application identifier

`TargetApp.AppId` matches the `AppId` column in the sign-in table. This is the application/client ID represented by the sign-in event.

Do not substitute:

- the enterprise application's service principal object ID;
- `ResourceId`;
- `ResourceServicePrincipalId`;
- a display name.

If the business question is about access to a resource API rather than sign-in to a client application, clone and review the KQL semantics instead of silently changing this report.

## Interactive and non-interactive events

`SigninLogs` represents the interactive source used by this report. `AADNonInteractiveUserSignInLogs` contains non-interactive user sign-ins such as token-based activity where the user does not directly provide an authentication factor.

Defaulting `IncludeNonInteractiveSignIns` to `true` is useful for the broad operational question “when did this app last access Entra on behalf of the user?” It may not mean that the user actively opened or used the application at that time.

Set it to `false` when the approved definition is explicitly limited to interactive sign-ins. Record that decision in the internal runbook supplied with the report.

The CSV keeps `LastInteractiveSignInDateTime` and
`LastNonInteractiveSignInDateTime` separate. A `NonInteractiveOnly` row includes
a Japanese warning that the evidence may be token activity rather than direct
human interaction. If non-interactive logs aren't queried, the output says so
explicitly instead of treating the empty column as proof that no such activity
exists.

## Human-readable output

The original English columns remain in place for backward compatibility. The
report adds:

- `SignInFoundJa`
- `QueriedSignInTypes` and `QueriedSignInTypesJa`
- `SignInPattern` and `SignInPatternJa`
- `LastInteractiveSignInDateTime`
- `LastNonInteractiveSignInDateTime`
- `EvaluationWindowStartDateTime`
- `EvaluationWindowEndDateTime`
- `NoteJa`

Patterns are `Both`, `InteractiveOnly`, `NonInteractiveOnly`, and
`NoSignInRecord` when both sources are queried. Interactive-only mode uses
`InteractiveObserved` or `NoInteractiveSignInRecord` so an unqueried source is
never presented as a negative result.

## KQL and performance

The template performs early filters on:

- the requested UTC time window;
- validated `AppId`;
- successful result values;
- a dynamic array of target user object IDs.

It then summarizes to one row per matching user. The PowerShell process does not download raw events.

Group members are split into batches (default 500). A smaller batch reduces query text and result size but makes more requests. A larger batch makes fewer requests but should be tested against Workspace query limits. The implementation caps batches at 1,000.

Interactive and non-interactive tables are queried separately. This avoids a cross-table `union`, makes table-specific ingestion problems visible, and is easier to adapt where table plans have different query restrictions.

The cmdlet `Timespan` and explicit `TimeGenerated` conditions are both used. The first constrains the API request; the second keeps the KQL self-describing and auditable.

## Permissions

Microsoft Graph delegated scopes:

- `GroupMember.Read.All`
- `User.ReadBasic.All`

Azure authorization:

- access to run queries against the selected Workspace/table;
- preferably the current `Log Analytics Data Reader` built-in role at the narrowest approved scope, or an organization-approved custom role containing `Microsoft.OperationalInsights/workspaces/query/read`.

Graph consent and Azure RBAC are separate controls. Hidden-membership groups require additional Graph permission and a supported Entra role. This repository never grants roles or consent.

## Interpretation limits

`SignInFound=False` means:

> No successful event matching the selected app, current user ID, selected tables, and requested period was returned.

It does not prove:

- that the user has never used the application;
- that the Workspace retained the full requested period;
- that the relevant diagnostic category was enabled for the full period;
- that ingestion was complete and without latency;
- that the application ID represents the intended resource;
- that a successful token event represents meaningful human activity.

## Failure behavior

The script stops without replacing the final CSV when it detects:

- invalid or secret-like configuration;
- malformed or empty required GUIDs;
- unsupported membership mode, table, or batch size;
- Graph or Azure authentication failure;
- missing table or KQL error;
- query timeout or permissions failure;
- invalid KQL token replacement.

If non-interactive data isn't collected, set `IncludeNonInteractiveSignIns` to `false` only after confirming that interactive-only reporting matches the business question. Do not silently treat a missing table as zero activity.

## Operational checklist

Before first use:

- Verify Workspace Customer ID, tenant, subscription, group object ID, and application/client ID with a second person.
- Confirm that diagnostic settings have sent the intended sign-in categories to the Workspace.
- Confirm actual retention and table plan for the requested period.
- Decide whether non-interactive events count for the request.
- Confirm the recipient and approved CSV storage location.
- Run the KQL manually against a non-production or known test case.

For every report:

- Check the authenticated Azure tenant/subscription and Graph tenant.
- Review member count, batch count, table count, and aggregated-row count.
- Investigate unexpected zero counts before distributing the report.
- Share only the CSV, not the operational log, configuration, Workspace details, or raw KQL results unless separately approved.

The `SignInReview` module supports reuse of configuration validation, Graph
lookups, KQL templating, Log Analytics queries, review classification, logging,
and atomic CSV export. The administrator dormancy review remains a separate
script, configuration schema, KQL template, output contract, and security
review.
