-- System tables: core-owned data a module may be granted read access to,
-- table by table, with a reason an operator approved.
--
-- Deliberately small and boring. This is the surface a third party can be let
-- near, so anything that grows here should be argued for rather than assumed.
\connect siberian_configuration

CREATE TABLE IF NOT EXISTS settings (
  key         text PRIMARY KEY,
  value       text NOT NULL,
  description text,
  updated_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE settings IS 'Product-wide settings. Readable by modules that were granted it.';

INSERT INTO settings (key, value, description) VALUES
  ('locale',      'en',                 'Language the product renders in'),
  ('date_format', 'YYYY-MM-DD',         'How dates are written across the product'),
  ('time_zone',   'UTC',                'Time zone for display'),
  ('brand_name',  'Siberian',           'Name shown in the product shell')
ON CONFLICT (key) DO NOTHING;

CREATE TABLE IF NOT EXISTS feature_flags (
  name        text PRIMARY KEY,
  enabled     boolean NOT NULL DEFAULT false,
  description text,
  updated_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE feature_flags IS 'Flags modules may read so they match the product they are embedded in.';

INSERT INTO feature_flags (name, enabled, description) VALUES
  ('dark_mode',        true,  'Product shell offers a dark theme'),
  ('module_analytics', false, 'Modules may report usage counters')
ON CONFLICT (name) DO NOTHING;
