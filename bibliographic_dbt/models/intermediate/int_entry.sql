{{ config(materialized='table') }}

WITH distinct_entries AS (
    SELECT DISTINCT
        id AS source_id,
        doi,
        title,
        publisher,
        type,
        publication_date,
        language,
        authors,
        score,
        container_title,
        page,
        isbn,
        reference_count,
        is_referenced_by_count,
        citations,
        cited_by,
        volume,
        issue,
        REGEXP_REPLACE(CAST(abstract AS VARCHAR), '<[^>]+>', '', 'g') AS abstract,
        raw_data,
        CURRENT_TIMESTAMP AS updated_at,
        {{ surrogate_key(["id", "doi", "title", "publisher"]) }} AS entry_id
    FROM {{ ref('stg_crossref') }}
    WHERE title IS NOT NULL
)
SELECT
    entry_id,
    source_id,
    doi,
    title,
    publisher,
    type,
    publication_date,
    language,
    authors,
    score,
    container_title,
    page,
    isbn,
    reference_count,
    is_referenced_by_count,
    citations,
    cited_by,
    volume,
    issue,
    abstract,
    raw_data,
    updated_at
FROM distinct_entries