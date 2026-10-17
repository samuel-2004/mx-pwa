# Supabase Edge Functions

This directory contains the Edge Function sources used by MX:

- `create-game` creates a game and its first admin account.
- `join-game` creates a player account for an existing game.
- `manage-users` lets an authenticated game admin manage player accounts.

## Deployment

Deploy these functions to the Supabase project used by the app. Authenticate with the Supabase CLI and link the intended project before deploying. The CLI's standard layout is `supabase/functions/<function-name>`; this repository stores the sources in `supabase_functions/`, so map or stage them into the configured functions directory for your deployment process.

Deploy each function by name:

```sh
supabase functions deploy create-game --project-ref <project-ref>
supabase functions deploy join-game --project-ref <project-ref>
supabase functions deploy manage-users --project-ref <project-ref>
```

Check the Supabase CLI deployment guide for current setup details: <https://supabase.com/docs/guides/functions/deploy>.

## Configuration and access

Configure server-side function secrets in Supabase. Never put a service-role key or other server secret in the Flutter app, `client.env.json`, request examples, or this repository's documentation.

`create-game` and `join-game` accept account-creation requests. Add appropriate abuse controls before exposing them publicly. `manage-users` verifies the caller's access token and allows only a game admin to manage users. Database row-level security remains necessary for client-side data access.

Do not log passwords or complete request bodies. Use placeholder values in manual API examples, and avoid committing real user credentials or account identifiers.
