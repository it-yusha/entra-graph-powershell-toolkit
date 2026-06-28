# App last sign-in by group: design and operations

## Processing flow

1. Validate the JSON configuration before authentication.
2. Connect interactively with delegated read permissions.
3. Read direct or transitive group members, casting the result to users.
4. Query sign-ins by UTC time range and `appId`.
5. Optionally discard events whose `status.errorCode` is not zero.
6. Select the newest event for each `userId`.
7. Merge with the existing CSV by stable `UserId`.
8. Retain the later of the existing and newly observed timestamps.
9. Mark removed members or exclude them according to configuration.
10. Neutralize formula-like text fields before CSV export.
11. Replace the CSV through a temporary file and write a metadata-only log.

## Why transitive membership is the default

Operational access groups are often nested. `Transitive` returns a flattened effective membership and is usually closer to the question “which users belong to this access population?” `Direct` remains available when the request is specifically about objects directly assigned to the selected group.

The query uses the Graph type cast `microsoft.graph.user`. This avoids accidentally treating nested group objects, devices, contacts, or service principals as people.

## Merge rules

`UserId` is the identity key because UPN and display name can change. The configured `AppId` defines the other side of the relationship, and one output CSV is limited to one app.

For a current member:

| Previous value | Current-window event | Result |
|---|---|---|
| empty | none | empty, with an explicit “not proof of never used” note |
| timestamp | none | retain previous timestamp |
| empty | timestamp | use observed timestamp |
| timestamp A | timestamp B | use the later timestamp |

For a removed member:

- `Retain`: preserve the row and timestamp, set `CurrentGroupMember=False`.
- `Exclude`: omit the row from the newly written file.

`Retain` is the safer general-purpose default. If erasure or minimization policy requires eventual deletion, implement that policy in the internal operational version with approval and a separate archive of record.

## Interpretation boundaries

The report answers:

> What is the latest successful sign-in for this app that this process has observed for each user in the selected group?

It does not prove:

- that an empty row has never used the app;
- that a sign-in is equivalent to meaningful business activity;
- that the app was opened interactively, unless the organization has validated the relevant sign-in event types;
- that events older than the tenant retention window do not exist;
- that a very recent event has already reached the reporting API.

The endpoint's `appId` represents the application/client ID shown in the sign-in event. If the business question concerns access to a resource API rather than use of a client application, validate whether `resourceId`, `resourceServicePrincipalId`, or exported diagnostic logs are the correct source before adapting the internal version.

## Operational checklist

Before first use:

- Confirm the group object ID and application ID with a second person.
- Confirm whether nested membership is intended.
- Confirm the tenant's sign-in log retention and license.
- Confirm that successful sign-ins are the accepted definition of “used.”
- Store the CSV in an access-controlled location.
- Define who can run the report and receive its output.
- Test with a non-production group and dummy output path.

For each run:

- Review the tenant ID shown after connection.
- Review member and event counts in the log.
- Treat a sudden zero count as a possible filter, permission, retention, or latency issue.
- Do not attach the CSV to public tickets or commit it.

For production adoption:

- Pin and test a supported Microsoft Graph PowerShell SDK version.
- Add Pester tests for organization-specific configuration and merge rules.
- Add code signing or execution policy controls as required.
- Define change review, output retention, incident handling, and owner succession.
- Prefer a governed log export when long-term audit history is required.

## Error behavior

The script stops before replacing the output when it detects:

- missing or malformed configuration;
- an empty GUID;
- a secret-like field in JSON;
- authentication or Graph request failure;
- a malformed historical timestamp;
- duplicate `UserId` rows;
- an existing row for a different app.

Operational logs contain timestamps, levels, tenant ID, paths, and counts, but intentionally do not write UPNs, names, user IDs, or sign-in event bodies.
