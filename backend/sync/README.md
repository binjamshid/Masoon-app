# Server sync logic

This directory contains the TypeScript logic used to validate a plan event,
project a pull page, and checksum a policy. It can be exercised offline with
synthetic events.

| File          | Behavior                                                                                                                                                                                                                                                                                                                                                     |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `validate.ts` | `validateEventEnvelope` checks a decoded JSON event, normalizes its UUIDv7 ID, drops server-owned fields, and preserves unfamiliar event types and versions with a warning. When handling an `override.applied` event, call `validateOverridePayload` to check the shape of the optional supersession fields.                                                |
| `page.ts`     | `projectPlanEventsPage` accepts rows for one plan that the caller is authorized to read. Supply rows strictly after the cursor, in ascending server sequence, with up to 501 rows so the extra row can indicate another page. The response includes up to 500 events and a continuation cursor pointing to the last returned sequence when more rows remain. |
| `checksum.ts` | `policyChecksum` computes lowercase SHA-256 over canonical JSON. It accepts JSON-compatible policy values and sorts object keys recursively while preserving array order.                                                                                                                                                                                    |

The cursor is base64-encoded JSON with a plan ID and a server sequence. Treat a
cursor returned by a client as untrusted input and verify plan access before
selecting rows. Authorization, request handling, storage, and batch processing
are outside this module.

## Run the focused tests

With Deno 2 installed, run from the repository root:

```sh
deno test --no-config --no-remote --no-check backend/sync/sync_test.ts
```

The tests use Deno's built-in Node compatibility module for assertions and
require no network access, database, environment variables, or corpus files.
