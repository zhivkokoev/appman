import '../db/credential_store.dart';
import 'dotenv.dart';

enum EnvChange { added, updated, unchanged }

class EnvImportPlanItem {
  EnvImportPlanItem(this.key, this.change);
  final String key;
  final EnvChange change;
}

class EnvImportSummary {
  EnvImportSummary(this.added, this.updated, this.unchanged);
  final int added, updated, unchanged;
  String get text => '$added added, $updated updated, $unchanged unchanged';
}

/// Merges parsed `.env` entries into an environment's runtime secrets (spec F5).
/// Existing keys keep their record (history, notes, expiry); only the value changes.
class EnvImporter {
  EnvImporter(this._store, this.environmentId);
  final CredentialStore _store;
  final String environmentId;

  List<Credential> _existing() => _store.listFor(
    Owner.environment(environmentId),
    purpose: CredentialPurpose.runtime,
  );

  /// What [apply] would do, without changing anything (used for the preview).
  List<EnvImportPlanItem> plan(Iterable<EnvEntry> entries) {
    final byKey = {for (final c in _existing()) c.keyName: c};
    return [
      for (final e in entries)
        EnvImportPlanItem(e.key, switch (byKey[e.key]) {
          null => EnvChange.added,
          final c when c.secret == e.value => EnvChange.unchanged,
          _ => EnvChange.updated,
        }),
    ];
  }

  EnvImportSummary apply(Iterable<EnvEntry> entries) {
    final byKey = {for (final c in _existing()) c.keyName: c};
    var added = 0, updated = 0, unchanged = 0;
    for (final e in entries) {
      final c = byKey[e.key];
      if (c == null) {
        _store.create(
          owner: Owner.environment(environmentId),
          purpose: CredentialPurpose.runtime,
          type: 'envVar',
          label: '',
          keyName: e.key,
          secret: e.value,
        );
        added++;
      } else if (c.secret != e.value) {
        _store.update(
          c.copyWith(secret: e.value),
        ); // keeps the old value in history
        updated++;
      } else {
        unchanged++;
      }
    }
    return EnvImportSummary(added, updated, unchanged);
  }
}
