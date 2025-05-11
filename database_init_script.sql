-- PostgreSQL DDL for the dwh Schema
-- Includes partitioning, indexes, and constraints.
-- Requires PostgreSQL 13+. Assumes schema "dwh" already exists.
-----------------------------------------------------------------------------
-- 0. Extension & Search Path -----------------------------------------------
-----------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA dwh;
SET search_path = dwh, pg_catalog;

-----------------------------------------------------------------------------
-- 1. Dimension Tables ------------------------------------------------------
-----------------------------------------------------------------------------

DROP TABLE IF EXISTS dwh.author CASCADE;
CREATE TABLE dwh.author (
    author_id      bigint PRIMARY KEY,
    name           text,
    orcid          text,
    organizations  text, -- Raw text/JSON of affiliations
    updated_at     timestamptz
);
CREATE INDEX IF NOT EXISTS idx_author_name_trgm ON dwh.author USING gin (name dwh.gin_trgm_ops); -- For ILIKE search

DROP TABLE IF EXISTS dwh.organization CASCADE;
CREATE TABLE dwh.organization (
    id        bigint PRIMARY KEY,
    name      text UNIQUE, -- Canonicalized organization name
    address   text,
    contact_1 text,
    contact_2 text,
    email     text,
    org_type  text,
    updated_at timestamptz
);

DROP TABLE IF EXISTS dwh.entry_type CASCADE;
CREATE TABLE dwh.entry_type (
    entry_type_id   bigint PRIMARY KEY,
    entry_type_name text UNIQUE, -- Controlled vocabulary type name
    entry_type_desc text
);

-----------------------------------------------------------------------------
-- 2. Fact & Bridge Tables --------------------------------------------------
-----------------------------------------------------------------------------

-- Entry table, range-partitioned by publication year
DROP TABLE IF EXISTS dwh.entry CASCADE;
CREATE TABLE dwh.entry (
    entry_id               bigint         NOT NULL,
    source_id              bigint,
    doi                    text,
    title                  text,
    publisher              text,
    type                   text, -- Original type string from source
    entry_type_id          bigint, -- FK to dwh.entry_type
    publication_date       date           NOT NULL, -- Partition key
    language               text,
    score                  double precision,
    container_title        text,
    page                   text,
    isbn                   jsonb,
    reference_count        integer,
    is_referenced_by_count integer,
    citations              jsonb,
    cited_by               jsonb,
    volume                 text,
    issue                  text,
    abstract               text,
    raw_data               jsonb,
    updated_at             timestamptz,
    fts                    tsvector, -- Precomputed full-text search vector
    PRIMARY KEY (entry_id, publication_date) -- Includes partition key
) PARTITION BY RANGE (publication_date);

-- Generate yearly partitions for dwh.entry (2000-2030 + legacy)
DO $$
DECLARE
    yr int;
BEGIN
    FOR yr IN 2000..2030 LOOP
        EXECUTE format(
            ‘CREATE TABLE IF NOT EXISTS dwh.entry_y%s PARTITION OF dwh.entry
             FOR VALUES FROM (‘‘%s-01-01’’) TO (‘‘%s-01-01’’);’,
            yr, yr, yr + 1
        );
    END LOOP;
    EXECUTE ‘CREATE TABLE IF NOT EXISTS dwh.entry_legacy PARTITION OF dwh.entry
             FOR VALUES FROM (‘‘1900-01-01’’) TO (‘‘2000-01-01’’);’; -- Fallback partition
END$$;

-- Entry-Author bridge table, hash-partitioned by entry_id
DROP TABLE IF EXISTS dwh.entry_author CASCADE;
CREATE TABLE dwh.entry_author (
    entry_author_surrogate_id bigint NOT NULL,
    author_id                 bigint NOT NULL, -- FK to dwh.author
    entry_id                  bigint NOT NULL, -- Refers to entry_id in dwh.entry
    is_primary_author         boolean,
    author_sequence           integer, -- Order of author in the publication
    updated_at                timestamptz,
    PRIMARY KEY (entry_id, author_id)
) PARTITION BY HASH (entry_id);

-- Generate hash partitions for dwh.entry_author (32 buckets)
DO $$
DECLARE i int;
BEGIN
    FOR i IN 0..31 LOOP
        EXECUTE format(
            ‘CREATE TABLE IF NOT EXISTS dwh.entry_author_p%s PARTITION OF dwh.entry_author
             FOR VALUES WITH (MODULUS 32, REMAINDER %s);’,
            i, i
        );
    END LOOP;
END$$;

-- Author-Organization bridge table
DROP TABLE IF EXISTS dwh.author_organization CASCADE;
CREATE TABLE dwh.author_organization (
    author_organization_surrogate_id bigint PRIMARY KEY,
    author_id                 bigint NOT NULL, -- FK to dwh.author
    organization_id           bigint NOT NULL, -- FK to dwh.organization
    affiliation_sequence      integer, -- Order of affiliation for the author
    is_primary_organization   boolean,
    updated_at                timestamptz
);

-----------------------------------------------------------------------------
-- 3. Indexes ---------------------------------------------------------------
-----------------------------------------------------------------------------
-- GIN trigram index for case-insensitive title search
CREATE INDEX IF NOT EXISTS idx_entry_title_trgm ON dwh.entry USING gin (title dwh.gin_trgm_ops);

-- Full-text search index using precomputed ‘fts’ column
CREATE INDEX IF NOT EXISTS idx_entry_fts ON dwh.entry USING gin (fts);

-- Index for sorting entries by recent publication date
CREATE INDEX IF NOT EXISTS idx_entry_recent ON dwh.entry (publication_date DESC);

-- Covering index for entry-author lookups
CREATE INDEX IF NOT EXISTS idx_entry_author_lookup ON dwh.entry_author (entry_id, author_id);

-- Indexes for author-organization lookups
CREATE INDEX IF NOT EXISTS idx_author_org_author_lookup ON dwh.author_organization (author_id);
CREATE INDEX IF NOT EXISTS idx_author_org_org_lookup ON dwh.author_organization (organization_id);

-----------------------------------------------------------------------------
-- 4. Full-Text Search Trigger ----------------------------------------------
-----------------------------------------------------------------------------
-- Trigger function to update the ‘fts’ tsvector column in dwh.entry
CREATE OR REPLACE FUNCTION dwh.update_fts() RETURNS trigger AS $$
BEGIN
  NEW.fts := to_tsvector(‘simple’, coalesce(NEW.title,’’) || ‘ ‘ || coalesce(NEW.abstract,’’));
  RETURN NEW;
END
$$ LANGUAGE plpgsql;

-- Trigger definition for dwh.entry updates/inserts
DROP TRIGGER IF EXISTS trg_update_fts ON dwh.entry;
CREATE TRIGGER trg_update_fts
BEFORE INSERT OR UPDATE ON dwh.entry
FOR EACH ROW EXECUTE FUNCTION dwh.update_fts();

-----------------------------------------------------------------------------
-- 5. Foreign Key Constraints -----------------------------------------------
-----------------------------------------------------------------------------
-- Constraints added with DEFERRABLE INITIALLY IMMEDIATE as per thesis text

ALTER TABLE dwh.entry
ADD CONSTRAINT fk_entry_entry_type
FOREIGN KEY (entry_type_id) REFERENCES dwh.entry_type(entry_type_id)
DEFERRABLE INITIALLY IMMEDIATE;

ALTER TABLE dwh.entry_author
ADD CONSTRAINT fk_entry_author_author
FOREIGN KEY (author_id) REFERENCES dwh.author(author_id)
DEFERRABLE INITIALLY IMMEDIATE;

ALTER TABLE dwh.author_organization
ADD CONSTRAINT fk_author_organization_author
FOREIGN KEY (author_id) REFERENCES dwh.author(author_id)
DEFERRABLE INITIALLY IMMEDIATE;

ALTER TABLE dwh.author_organization
ADD CONSTRAINT fk_author_organization_organization
FOREIGN KEY (organization_id) REFERENCES dwh.organization(id)
DEFERRABLE INITIALLY IMMEDIATE;

-- Note: A direct FK from dwh.entry_author to the partitioned dwh.entry table
-- is omitted due to the complexity of referencing a composite partitioned key.
-- This relationship integrity is intended to be enforced via DBT tests.

-----------------------------------------------------------------------------
-- End of DDL Script --------------------------------------------------------
-----------------------------------------------------------------------------
