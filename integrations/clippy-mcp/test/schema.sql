-- Throwaway schema mirroring Clippy's GRDB-built tables (post-migration v10).
-- Derived from Sources/Clippy/Storage/ClipDatabase+Migrations.swift.

CREATE TABLE clips (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  contentText TEXT NOT NULL,
  contentRTF BLOB,
  contentHTML BLOB,
  typeIdentifier TEXT NOT NULL,
  sourceAppBundleID TEXT,
  sourceAppName TEXT,
  createdAt DATETIME NOT NULL,
  contentKind TEXT NOT NULL DEFAULT 'text',
  mediaFilename TEXT,
  thumbFilename TEXT,
  pixelWidth INTEGER,
  pixelHeight INTEGER,
  byteSize INTEGER,
  userTitle TEXT,
  filePath TEXT,
  ocrText TEXT
);
CREATE INDEX index_clips_on_createdAt ON clips(createdAt);

CREATE TABLE category (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  colorHex TEXT NOT NULL,
  iconKind TEXT NOT NULL,
  iconValue TEXT NOT NULL,
  sortOrder INTEGER NOT NULL DEFAULT 0,
  isStarter BOOLEAN NOT NULL DEFAULT 0,
  createdAt DATETIME NOT NULL
);
CREATE UNIQUE INDEX category_single_starter ON category (isStarter) WHERE isStarter = 1;

CREATE TABLE clip_category (
  clipID INTEGER NOT NULL REFERENCES clips(id) ON DELETE CASCADE,
  categoryID INTEGER NOT NULL REFERENCES category(id) ON DELETE CASCADE,
  addedAt DATETIME NOT NULL,
  PRIMARY KEY (clipID, categoryID)
);
CREATE INDEX index_clip_category_on_clipID ON clip_category(clipID);

-- FTS5 synchronized with clips on (contentText, userTitle, ocrText), mirroring
-- GRDB's synchronize(withTable:). The triggers keep the index in sync.
CREATE VIRTUAL TABLE clips_fts USING fts5(
  contentText,
  userTitle,
  ocrText,
  content='clips',
  content_rowid='id',
  tokenize='unicode61'
);

CREATE TRIGGER __clips_fts_ai AFTER INSERT ON clips BEGIN
  INSERT INTO clips_fts(rowid, contentText, userTitle, ocrText)
  VALUES (new.id, new.contentText, new.userTitle, new.ocrText);
END;
CREATE TRIGGER __clips_fts_ad AFTER DELETE ON clips BEGIN
  INSERT INTO clips_fts(clips_fts, rowid, contentText, userTitle, ocrText)
  VALUES ('delete', old.id, old.contentText, old.userTitle, old.ocrText);
END;
CREATE TRIGGER __clips_fts_au AFTER UPDATE ON clips BEGIN
  INSERT INTO clips_fts(clips_fts, rowid, contentText, userTitle, ocrText)
  VALUES ('delete', old.id, old.contentText, old.userTitle, old.ocrText);
  INSERT INTO clips_fts(rowid, contentText, userTitle, ocrText)
  VALUES (new.id, new.contentText, new.userTitle, new.ocrText);
END;
CREATE TABLE smart_collections (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  rule TEXT NOT NULL,
  sortOrder INTEGER NOT NULL DEFAULT 0
);
