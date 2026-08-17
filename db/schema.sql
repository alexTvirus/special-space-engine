-- ============================================================================
-- IT Knowledge Base Pipeline — Postgres schema
-- Implements Storage Layer (C) from the design doc: 1 database instead of
-- Postgres + Qdrant + Elasticsearch + Neo4j + Redis/Celery.
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS unaccent;

-- pg_trgm: enables a GIN trigram index on knowledge_atoms.raw/normalized so
-- term_exists_in_corpus()'s `ILIKE '%term%'` (leading wildcard — a plain
-- B-tree index can't be used for this pattern at all) stops being a full
-- sequential scan of the whole table on every call. See idx_atoms_raw_trgm /
-- idx_atoms_normalized_trgm below.
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- ----------------------------------------------------------------------------


-- A3.5 — section content hashes (change detection between ingest runs)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS section_hashes (
    source_id     TEXT NOT NULL,
    section_id    TEXT NOT NULL,
    content_hash  TEXT NOT NULL,
    updated_at    TIMESTAMP DEFAULT now(),
    PRIMARY KEY (source_id, section_id)
);

-- ----------------------------------------------------------------------------
-- A4 — job queue, replaces Celery + Redis
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS section_jobs (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    batch_id      UUID NOT NULL,
    source_id     TEXT NOT NULL,
    section_id    TEXT NOT NULL,
    section_text  TEXT NOT NULL,
    status        TEXT NOT NULL DEFAULT 'pending',  -- pending|processing|done|manual_review|failed
    attempt       INT NOT NULL DEFAULT 0,
    max_attempts  INT NOT NULL DEFAULT 3,
    llm_tier      TEXT NOT NULL DEFAULT 'light',     -- light|strong
    next_run_at   TIMESTAMP NOT NULL DEFAULT now(),
    last_error    TEXT,
    heading TEXT,
    created_at    TIMESTAMP DEFAULT now(),
    updated_at    TIMESTAMP DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_section_jobs_poll
    ON section_jobs (status, next_run_at);

-- ----------------------------------------------------------------------------
-- Knowledge atoms == verified elements after A4 (+ dedup B1 + embeddings B2)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS knowledge_atoms (
    id                TEXT PRIMARY KEY,           -- stable element id
    source_id         TEXT NOT NULL,
    section_id        TEXT NOT NULL,
    chapter           TEXT,
    page_start        INT,
    label             TEXT,                       -- FACT|DEFINITION|CONSTRAINT|EXAMPLE|WARNING|OTHER
    raw               TEXT NOT NULL,               -- verbatim substring from source (A4 verification)
    normalized        TEXT,                        -- LLM-normalized/paraphrased form
    confidence        REAL,
    contradicts_flag  BOOLEAN DEFAULT FALSE,
    embedding         vector(1024),
    search_vector     tsvector,
    -- A4.5/B2: raw {"name","type"} entity mentions copied from
    -- ExtractedElement.entities by B1, later mutated in place by A4.5 to add
    -- a resolved "entity_id" once the source_id's entity_map is built. B2's
    -- MENTIONS edge builder reads entity_id straight out of this column.
    entities          JSONB DEFAULT '[]',
    created_at        TIMESTAMP DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_atoms_embedding
    ON knowledge_atoms USING hnsw (embedding vector_cosine_ops);
CREATE INDEX IF NOT EXISTS idx_atoms_search
    ON knowledge_atoms USING gin (search_vector);
CREATE INDEX IF NOT EXISTS idx_atoms_source_section
    ON knowledge_atoms (source_id, section_id);
CREATE INDEX IF NOT EXISTS idx_atoms_raw_trgm
    ON knowledge_atoms USING gin (raw gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_atoms_normalized_trgm
    ON knowledge_atoms USING gin (normalized gin_trgm_ops);

CREATE OR REPLACE FUNCTION knowledge_atoms_search_vector_trigger() RETURNS trigger AS $$
BEGIN
  NEW.search_vector := to_tsvector('simple', coalesce(NEW.normalized, NEW.raw, ''));
  RETURN NEW;
END
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_atoms_search_vector ON knowledge_atoms;
CREATE TRIGGER trg_atoms_search_vector
BEFORE INSERT OR UPDATE ON knowledge_atoms
FOR EACH ROW EXECUTE FUNCTION knowledge_atoms_search_vector_trigger();

-- ----------------------------------------------------------------------------
-- B2 — Knowledge Graph (replaces Neo4j)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS kg_nodes (
    id         TEXT PRIMARY KEY,
    label      TEXT,
    type       TEXT,   -- entity|atom
    -- Scopes an entity/atom node to the document it belongs to. Lets
    -- get_nodes_edges_for_source() (B2.5 Louvain input) and other
    -- per-document queries avoid pulling in the whole corpus's graph.
    -- Nullable for backward compat with any pre-existing rows.
    source_id  TEXT,
    tier       TEXT NOT NULL DEFAULT 'structural'  -- 'reasoning' | 'structural'
);
CREATE INDEX IF NOT EXISTS idx_kg_nodes_source ON kg_nodes(source_id);
CREATE INDEX IF NOT EXISTS idx_kg_nodes_tier ON kg_nodes(tier);

CREATE TABLE IF NOT EXISTS kg_edges (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source_id    TEXT REFERENCES kg_nodes(id),
    target_id    TEXT REFERENCES kg_nodes(id),
    relation     TEXT NOT NULL,       -- MENTIONS|SIMILAR_TO|DEFINES|EXTENDS|CONTRADICTS|RELATED_TO
    -- Only DEFINES/EXTENDS/CONTRADICTS/RELATED_TO carry a verbatim-substring
    -- evidence quote; MENTIONS/SIMILAR_TO are purely structural, so this is
    -- nullable now (was NOT NULL, which made those two relations impossible
    -- to insert without inventing a fake "evidence" string).
    evidence_raw TEXT,
    -- Only meaningful for MENTIONS (always 1.0) and SIMILAR_TO (ANN cosine
    -- score from A4.8) — see common/schemas.py::KGEdge docstring for why this
    -- is a separate column instead of being crammed into evidence_raw.
    score        REAL,
    tier         TEXT NOT NULL DEFAULT 'structural',
    UNIQUE (source_id, target_id, relation)
);
CREATE INDEX IF NOT EXISTS idx_edges_source ON kg_edges(source_id);
CREATE INDEX IF NOT EXISTS idx_edges_target ON kg_edges(target_id);
CREATE INDEX IF NOT EXISTS idx_edges_relation ON kg_edges(relation);
CREATE INDEX IF NOT EXISTS idx_edges_tier ON kg_edges(tier);

-- Giai đoạn 0 — tầng Fact
CREATE TABLE IF NOT EXISTS kg_facts (
    id                 TEXT PRIMARY KEY,
    source_id          TEXT,
    source_entity_id   TEXT REFERENCES kg_nodes(id),
    target_entity_id   TEXT REFERENCES kg_nodes(id),
    relation_type      TEXT NOT NULL,
    confidence         REAL DEFAULT 0.0,
    created_at         TIMESTAMP DEFAULT now(),
    updated_at         TIMESTAMP DEFAULT now(),
    UNIQUE (source_entity_id, target_entity_id, relation_type)
);
CREATE INDEX IF NOT EXISTS idx_kg_facts_source_entity ON kg_facts(source_entity_id);
CREATE INDEX IF NOT EXISTS idx_kg_facts_target_entity ON kg_facts(target_entity_id);
CREATE INDEX IF NOT EXISTS idx_kg_facts_source ON kg_facts(source_id);

CREATE TABLE IF NOT EXISTS fact_evidence (
    fact_id       TEXT NOT NULL REFERENCES kg_facts(id) ON DELETE CASCADE,
    atom_id       TEXT NOT NULL REFERENCES knowledge_atoms(id) ON DELETE CASCADE,
    evidence_raw  TEXT NOT NULL,
    confidence    REAL DEFAULT 1.0,
    PRIMARY KEY (fact_id, atom_id)
);
CREATE INDEX IF NOT EXISTS idx_fact_evidence_fact ON fact_evidence(fact_id);
CREATE INDEX IF NOT EXISTS idx_fact_evidence_atom ON fact_evidence(atom_id);

-- Migration guard cho DB đã tồn tại từ trước
ALTER TABLE kg_nodes ADD COLUMN IF NOT EXISTS tier TEXT NOT NULL DEFAULT 'structural';
ALTER TABLE kg_edges ADD COLUMN IF NOT EXISTS tier TEXT NOT NULL DEFAULT 'structural';
UPDATE kg_nodes SET tier = 'reasoning' WHERE type IN ('entity', 'type') AND tier = 'structural';
UPDATE kg_edges SET tier = 'reasoning' WHERE relation = 'INSTANCE_OF' AND tier = 'structural';

-- ----------------------------------------------------------------------------
-- Migration guard: the CREATE TABLE IF NOT EXISTS blocks above only take
-- effect on a brand-new database. On a database that already has these
-- tables from before this design-doc revision, run the ALTERs below (they
-- are themselves idempotent / safe to re-run).
-- ----------------------------------------------------------------------------
ALTER TABLE knowledge_atoms ADD COLUMN IF NOT EXISTS entities JSONB DEFAULT '[]';
ALTER TABLE kg_nodes ADD COLUMN IF NOT EXISTS source_id TEXT;
CREATE INDEX IF NOT EXISTS idx_kg_nodes_source ON kg_nodes(source_id);
ALTER TABLE kg_edges ADD COLUMN IF NOT EXISTS score REAL;
ALTER TABLE kg_edges ALTER COLUMN evidence_raw DROP NOT NULL;
-- Old rows may have relation values outside the previous DEFINES/EXTENDS/
-- CONTRADICTS/RELATED_TO set; MENTIONS/SIMILAR_TO are new, so nothing to
-- backfill. The uniqueness constraint below can't be added retroactively via
-- IF NOT EXISTS in plain SQL, so guard it with a DO block instead.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'kg_edges_source_id_target_id_relation_key'
    ) THEN
        BEGIN
            ALTER TABLE kg_edges ADD CONSTRAINT kg_edges_source_id_target_id_relation_key
                UNIQUE (source_id, target_id, relation);
        EXCEPTION WHEN unique_violation THEN
            RAISE NOTICE 'kg_edges has duplicate (source_id,target_id,relation) rows — '
                         'dedupe manually before this constraint can be added';
        END;
    END IF;
END $$;

-- ----------------------------------------------------------------------------
-- A4.5 — persisted, consolidated entity map (one row per resolved entity per
-- document). GlobalIndex.entity_map from A3 stays in-memory/ephemeral as
-- before; THIS table is the new artifact A4.5 builds from A4's per-sentence
-- `entities` (see stages/a4_5_entity_consolidation.py) and what A5/B2 read.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS entity_map (
    entity_id       TEXT PRIMARY KEY,
    source_id       TEXT NOT NULL,
    canonical_name  TEXT NOT NULL,
    type            TEXT NOT NULL,
    section_ids     JSONB DEFAULT '[]',
    section_count   INT DEFAULT 0,
    mention_count   INT DEFAULT 0,
    name_embedding  vector(1024),
    updated_at      TIMESTAMP DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_entity_map_source ON entity_map(source_id);

-- ----------------------------------------------------------------------------
-- B2.5 — community membership (Louvain partition), used to decide whether a
-- community actually changed before re-summarizing it with an LLM (lazy
-- summary, mirrors LazyGraphRAG).
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS community_membership (
    source_id     TEXT NOT NULL,
    community_id  TEXT NOT NULL,
    member_ids    JSONB NOT NULL,
    updated_at    TIMESTAMP DEFAULT now(),
    PRIMARY KEY (source_id, community_id)
);

-- ----------------------------------------------------------------------------
-- B2 — chunk records (parent/child, late chunking)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS chunk_records (
    id         TEXT PRIMARY KEY,
    type       TEXT NOT NULL,          -- parent|child
    content    TEXT NOT NULL,
    parent_id  TEXT REFERENCES chunk_records(id),
    embedding  vector(1024),
    metadata   JSONB,
    children    JSONB
);
CREATE INDEX IF NOT EXISTS idx_chunk_embedding
    ON chunk_records USING hnsw (embedding vector_cosine_ops);

ALTER TABLE chunk_records 
ADD COLUMN IF NOT EXISTS search_vector tsvector;

CREATE INDEX IF NOT EXISTS idx_chunk_records_search 
    ON chunk_records USING gin (search_vector);

CREATE OR REPLACE FUNCTION chunk_records_search_vector_trigger() RETURNS trigger AS $$
BEGIN
    -- Ưu tiên embed full content của parent chunk
    NEW.search_vector := to_tsvector('simple', coalesce(NEW.content, ''));
    RETURN NEW;
END
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_chunk_records_search_vector ON chunk_records;
CREATE TRIGGER trg_chunk_records_search_vector
BEFORE INSERT OR UPDATE ON chunk_records
FOR EACH ROW EXECUTE FUNCTION chunk_records_search_vector_trigger();

-- Phase 0 fix — backfill: the trigger functions above only run on future
-- INSERT/UPDATE, so any rows already ingested under the old 'english'
-- config would keep stale/wrong search_vector values until touched. Force a
-- recompute once via a no-op UPDATE (safe to re-run; this file is applied
-- as a repeatable migration like the rest of it).
UPDATE knowledge_atoms SET id = id;
UPDATE chunk_records SET id = id WHERE type = 'parent';
-- ----------------------------------------------------------------------------
-- C — batch monitoring (replaces Sentry + Flower)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS batch_runs (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    started_at              TIMESTAMP DEFAULT now(),
    finished_at             TIMESTAMP,
    total_documents         INT DEFAULT 0,
    total_sections          INT DEFAULT 0,
    failed_sections         INT DEFAULT 0,
    manual_review_sections  INT DEFAULT 0
);

-- ----------------------------------------------------------------------------
-- A5.9 — Fact-node layer (hybrid, additive) — xem
-- PHUONG_AN_FACT_NODE_HYBRID.md. KHÔNG đổi kg_facts/fact_evidence ở trên,
-- đây là 1 tầng SONG SONG chỉ cho câu mà entity-entity (kg_facts) không neo
-- được (state/event/error/metric có <2 entity phân biệt trong 1 atom) —
-- xem stages/a5_9_fact_node_extraction.py::_select_trigger_atoms cho điều
-- kiện trigger chính xác. Mặc định TẮT (settings.a5_9_fact_graph_enabled)
-- nên 2 bảng này rỗng cho tới khi feature được bật.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS fact_nodes (
    id           TEXT PRIMARY KEY,             -- factnode_{atom_id}_{seq}
    source_id    TEXT NOT NULL,
    atom_id      TEXT NOT NULL REFERENCES knowledge_atoms(id) ON DELETE CASCADE,  -- Evidence gốc
    section_id   TEXT,
    text         TEXT NOT NULL,                -- mệnh đề nguyên tử, VD "Cache miss"
    fact_type    TEXT NOT NULL DEFAULT 'STATE', -- STATE|EVENT|ACTION|CONFIG|ERROR|METRIC
    entity_ids   JSONB DEFAULT '[]',            -- optional — entity_id neo được, có thể rỗng
    embedding    vector(1024),
    created_at   TIMESTAMP DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_fact_nodes_source  ON fact_nodes(source_id);
CREATE INDEX IF NOT EXISTS idx_fact_nodes_atom    ON fact_nodes(atom_id);
CREATE INDEX IF NOT EXISTS idx_fact_nodes_embedding
    ON fact_nodes USING hnsw (embedding vector_cosine_ops);
-- entity_ids là JSONB array — dùng cho toán tử `?|` trong
-- db.get_fact_nodes_for_entities (xem common/db.py).
CREATE INDEX IF NOT EXISTS idx_fact_nodes_entity_ids ON fact_nodes USING gin (entity_ids);

-- Cạnh Fact-Fact — "Typed Fact Graph" song song kg_facts, nối 2 fact_nodes
-- thay vì 2 entity.
CREATE TABLE IF NOT EXISTS fact_fact_edges (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source_fact_id  TEXT NOT NULL REFERENCES fact_nodes(id) ON DELETE CASCADE,
    target_fact_id  TEXT NOT NULL REFERENCES fact_nodes(id) ON DELETE CASCADE,
    relation_type   TEXT NOT NULL,   -- CAUSES|REQUIRES|PRECEDES|MITIGATES|SUPPORTS|DEPENDS_ON
    -- 'intra_atom': 2 Fact tách ra từ CÙNG 1 atom, LLM trả luôn trong cùng
    --   lời gọi trích Fact (độ tin cậy cao — cùng câu, cùng evidence).
    -- 'cross_fact_llm': 2 Fact khác atom, qua bước Relation Verification
    --   riêng — phải qua candidate generator trước.
    origin          TEXT NOT NULL CHECK (origin IN ('intra_atom', 'cross_fact_llm')),
    confidence      REAL DEFAULT 0.0,
    created_at      TIMESTAMP DEFAULT now(),
    UNIQUE (source_fact_id, target_fact_id, relation_type)
);
CREATE INDEX IF NOT EXISTS idx_fact_fact_edges_source ON fact_fact_edges(source_fact_id);
CREATE INDEX IF NOT EXISTS idx_fact_fact_edges_target ON fact_fact_edges(target_fact_id);
