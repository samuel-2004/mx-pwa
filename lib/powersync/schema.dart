import 'package:powersync/powersync.dart';

// Client-side schema. PowerSync adds the text `id` column itself.
// Type mapping from Postgres: uuid, text and timestamptz become text,
// boolean becomes integer (0/1), jsonb becomes JSON text.
// Keep in sync with the deployed sync rules.
const Schema schema = Schema(<Table>[
  Table('users', [
    Column.text('uname'),
    Column.text('game_id'),
    Column.integer('is_admin'),
    Column.integer('is_subsection_admin'),
    Column.text('updated_at'),
    Column.text('deleted_at')
  ]),
  Table('answers', [
    Column.text('activity_id'),
    Column.text('user_id'),
    Column.text('answer'),
    Column.integer('points'),
    Column.integer('automatically_graded'),
    Column.text('created_at'),
    Column.text('submitted_by'),
    Column.text('graded_by'),
    Column.text('graded_at'),
    Column.text('updated_at'),
    Column.text('deleted_at')
  ]),
  Table('subsection_admins', [
    Column.text('user_id'),
    Column.text('subsection_id'),
    Column.text('updated_at'),
    Column.text('deleted_at')
  ]),
  Table('activities', [
    Column.text('game_id'),
    Column.text('subsection_id'),
    Column.text('name'),
    Column.text('answer_schema'),
    Column.integer('can_resubmit'),
    Column.integer('release_time_offset_minutes'),
    Column.integer('activity_order'),
    Column.integer('points'),
    Column.text('updated_at'),
    Column.text('deleted_at'),
    Column.text('desc')
  ]),
  Table('games', [
    Column.text('game_code'),
    Column.text('name'),
    Column.text('starts_at'),
    Column.text('game_options'),
    Column.text('updated_at'),
    Column.text('deleted_at')
  ]),
  Table('subsections', [
    Column.text('game_id'),
    Column.text('name'),
    Column.integer('subsection_order'),
    Column.text('updated_at'),
    Column.text('deleted_at'),
    Column.text('desc')
  ]),
  Table('user_activity_notes', [
    Column.text('user_id'),
    Column.text('activity_id'),
    Column.text('tags'),
    Column.real('lat'),
    Column.real('lng'),
    Column.text('suburb'),
    Column.real('suburb_lat'),
    Column.real('suburb_lng'),
    Column.text('updated_at'),
    Column.text('deleted_at'),
  ])
]);
