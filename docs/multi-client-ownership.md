# Multi-Client Ownership

`app_id` identifies an application, `instance_id` one process, and
`session_id` one connection. Temporary items and UDP generations belong to a
session and are removed on disconnect or lease expiry. Durable MIDI items
belong to the app and survive disconnect.

Item tags use exact `RPTK_RESOURCE_ID`, `RPTK_SESSION_ID`, `RPTK_APP_ID`,
`RPTK_KIND`, and bounded `RPTK_METADATA` fields. Replace and cleanup never use
name matching.

Only one session may own the global `transport_preview` lease. Ordinary item
insertion and UDP audition remain independent.

