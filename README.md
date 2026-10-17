# MX Scavenger Hunt

MX is a Flutter web app for running scavenger hunts. Admins create games and activities, manage players, and grade submissions. Players submit answers and follow their progress. PowerSync keeps app data available offline and syncs changes with Supabase.

## Requirements

- Flutter 3.47 or later
- Dart 3.13 or later
- A Supabase project and a PowerSync instance

## Configuration

Create a local `client.env.json` file for Flutter's `--dart-define-from-file` option. It should contain the public client configuration keys `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`, and `POWERSYNC_INSTANCE_URL`. Optional settings include `APP_URL`, `MAP_TILE_URL`, and `MAP_ATTRIBUTION`.

Only put public client configuration in this file. Never include a Supabase secret/service-role key, database password, or PowerSync replication password in the Flutter app or its web bundle.

## Run locally

From the project root:

```sh
dart run powersync:setup_web
flutter run --dart-define-from-file=client.env.json -d chrome
```

To build the web app:

```sh
dart run powersync:setup_web
flutter build web --dart-define-from-file=client.env.json
```

## Deploy to GitHub Pages

The repository includes a GitHub Actions workflow that builds the Flutter app
from `flutter_mx_v_0_3/` and deploys it as a project site at
`https://<owner>.github.io/<repository>/`. It runs on pushes to `main` and can
also be started manually from the Actions tab. If the repository uses a
different default branch, update the branch in
`../.github/workflows/deploy.yml`.

In the repository settings, set the Pages source to **GitHub Actions**. Add
these repository Actions variables under **Settings → Secrets and variables →
Actions → Variables**:

- `SUPABASE_URL`
- `SUPABASE_PUBLISHABLE_KEY`
- `POWERSYNC_INSTANCE_URL`

These values are compiled into the public web app, so only public client
configuration belongs here. The workflow sets `APP_URL` to the Pages site URL
for game join QR codes. Flutter's default hash URL strategy keeps app routes
working under the repository path.

## Supabase Functions

The `supabase_functions/` directory contains the `create-game`, `join-game`, and `manage-users` Edge Functions. See [the Functions README](supabase_functions/README.md) for deployment guidance.
