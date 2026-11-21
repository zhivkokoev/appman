/// Schema migrations. Index i holds the statements that move the DB from version i to i+1.
/// Every entity has `archived` (soft delete, see spec F10) and created/updated timestamps (epoch ms).
const List<List<String>> migrations = [
  [
    '''CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);''',
    '''CREATE TABLE applications(
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      description TEXT NOT NULL DEFAULT '',
      status TEXT NOT NULL DEFAULT 'active',      -- active | idea
      tags TEXT NOT NULL DEFAULT '',              -- comma separated
      notes TEXT NOT NULL DEFAULT '',             -- markdown
      criticality TEXT NOT NULL DEFAULT '',
      owner TEXT NOT NULL DEFAULT '',
      archived INTEGER NOT NULL DEFAULT 0,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    );''',
    '''CREATE TABLE repositories(
      id TEXT PRIMARY KEY,
      application_id TEXT NOT NULL REFERENCES applications(id),
      provider TEXT NOT NULL DEFAULT 'github',
      url TEXT NOT NULL,
      default_branch TEXT NOT NULL DEFAULT 'main',
      visibility TEXT NOT NULL DEFAULT '',
      local_path TEXT NOT NULL DEFAULT '',
      notes TEXT NOT NULL DEFAULT '',
      archived INTEGER NOT NULL DEFAULT 0,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    );''',
    '''CREATE TABLE hosting_targets(
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      provider TEXT NOT NULL DEFAULT '',
      account_id TEXT NOT NULL DEFAULT '',
      region TEXT NOT NULL DEFAULT '',
      console_url TEXT NOT NULL DEFAULT '',
      notes TEXT NOT NULL DEFAULT '',
      archived INTEGER NOT NULL DEFAULT 0,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    );''',
    '''CREATE TABLE environments(
      id TEXT PRIMARY KEY,
      application_id TEXT NOT NULL REFERENCES applications(id),
      hosting_target_id TEXT REFERENCES hosting_targets(id),
      name TEXT NOT NULL,
      urls TEXT NOT NULL DEFAULT '',              -- newline separated
      region TEXT NOT NULL DEFAULT '',
      deploy_method TEXT NOT NULL DEFAULT '',
      deploy_instructions TEXT NOT NULL DEFAULT '',
      version TEXT NOT NULL DEFAULT '',
      last_deployed INTEGER,
      notes TEXT NOT NULL DEFAULT '',
      archived INTEGER NOT NULL DEFAULT 0,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    );''',
    '''CREATE TABLE console_links(
      id TEXT PRIMARY KEY,
      label TEXT NOT NULL,
      url TEXT NOT NULL,
      type TEXT NOT NULL DEFAULT '',
      application_id TEXT REFERENCES applications(id),
      environment_id TEXT REFERENCES environments(id),
      hosting_target_id TEXT REFERENCES hosting_targets(id),
      archived INTEGER NOT NULL DEFAULT 0,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    );''',
    // purpose: access | runtime. Runtime secrets always have environment_id set (enforced in code).
    '''CREATE TABLE credentials(
      id TEXT PRIMARY KEY,
      purpose TEXT NOT NULL DEFAULT 'access',
      type TEXT NOT NULL DEFAULT 'password',
      label TEXT NOT NULL,
      key_name TEXT NOT NULL DEFAULT '',
      username TEXT NOT NULL DEFAULT '',
      secret TEXT NOT NULL DEFAULT '',
      url TEXT NOT NULL DEFAULT '',
      expires_at INTEGER,
      rotation_notes TEXT NOT NULL DEFAULT '',
      custom_fields TEXT NOT NULL DEFAULT '{}',   -- JSON
      notes TEXT NOT NULL DEFAULT '',
      application_id TEXT REFERENCES applications(id),
      environment_id TEXT REFERENCES environments(id),
      hosting_target_id TEXT REFERENCES hosting_targets(id),
      repository_id TEXT REFERENCES repositories(id),
      last_accessed_at INTEGER,
      archived INTEGER NOT NULL DEFAULT 0,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    );''',
    '''CREATE TABLE credential_history(
      id TEXT PRIMARY KEY,
      credential_id TEXT NOT NULL REFERENCES credentials(id),
      secret TEXT NOT NULL,
      changed_at INTEGER NOT NULL
    );''',
    '''CREATE TABLE attachments(
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      mime_type TEXT NOT NULL DEFAULT 'application/octet-stream',
      size INTEGER NOT NULL,
      data BLOB NOT NULL,
      application_id TEXT REFERENCES applications(id),
      environment_id TEXT REFERENCES environments(id),
      hosting_target_id TEXT REFERENCES hosting_targets(id),
      repository_id TEXT REFERENCES repositories(id),
      archived INTEGER NOT NULL DEFAULT 0,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    );''',
    'CREATE INDEX idx_repos_app ON repositories(application_id);',
    'CREATE INDEX idx_envs_app ON environments(application_id);',
    'CREATE INDEX idx_creds_env ON credentials(environment_id);',
    'CREATE INDEX idx_creds_app ON credentials(application_id);',
  ],
  // v2: change log (spec F10). Never contains secret values.
  [
    '''CREATE TABLE change_log(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      ts INTEGER NOT NULL,
      entity TEXT NOT NULL,
      entity_id TEXT NOT NULL,
      action TEXT NOT NULL,        -- create | update | archive | restore | purge | reveal | copy
      summary TEXT NOT NULL DEFAULT ''
    );''',
    'CREATE INDEX idx_log_entity ON change_log(entity, entity_id);',
    'CREATE INDEX idx_log_ts ON change_log(ts);',
    'CREATE INDEX idx_creds_expiry ON credentials(expires_at);',
    'CREATE INDEX idx_links_app ON console_links(application_id);',
    'CREATE INDEX idx_attach_app ON attachments(application_id);',
  ],
];
