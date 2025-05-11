WITH base AS (
    SELECT
        id,
        doi,
        title,
        publisher,
        type,
        issued::DATE AS publication_date,
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
        raw_data
    FROM {{ source('RAW', 'raw_crossref') }}
)
SELECT
    id,
    COALESCE(LOWER(doi), 'unknown') AS doi,
    TRIM(title) AS title,
    TRIM(publisher) AS publisher,
    LOWER(type) AS type,
    publication_date,
    LOWER(language) AS language,
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
    raw_data
FROM base
WHERE title IS NOT NULL
