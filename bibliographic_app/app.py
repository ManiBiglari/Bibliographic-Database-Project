from flask import Flask, render_template, request, jsonify, send_from_directory
import os
import psycopg2
from config import DB_CONFIG
import json

app = Flask(__name__, static_folder='static')

# Serve static files (fix missing CSS and images)
@app.route('/static/<path:filename>')
def static_files(filename):
    return send_from_directory(app.static_folder, filename)

# Database Connection
def get_db_connection():
    try:
        return psycopg2.connect(**DB_CONFIG)
    except psycopg2.Error as e:
        print(f"Database connection error: {e}")
        return None

# Add JSON filter
@app.template_filter('fromjson')
def fromjson(value):
    """
    Safely convert a JSON‑encoded string coming from the database into a Python
    object for Jinja templates. If the value is already a Python list or dict,
    just return it unchanged.
    """
    if isinstance(value, (list, dict)):
        return value
    try:
        return json.loads(value)
    except (TypeError, json.JSONDecodeError):
        return []

# Define the selected columns
SELECTED_COLUMNS = """
    doi, title, author_name, is_primary_author, orcid, publisher, publication_date,
    language, score, container_title, page, isbn, reference_count, is_referenced_by_count,
    citations, cited_by, volume, issue, organization_name, entry_type_name, abstract
"""

@app.route("/", methods=["GET"])
def home():
    """Render the search page with optional query results."""
    title_query = request.args.get("title", "").strip()
    author_query = request.args.get("author", "").strip()
    doi_query = request.args.get("doi", "").strip()
    selected_types = request.args.getlist("types")
    page = int(request.args.get("page", 0))
    per_page = int(request.args.get("per_page", 10))
    offset = page * per_page
    
    conn = get_db_connection()
    if not conn:
        return "Database connection error", 500

    try:
        cur = conn.cursor()
        
        # Get total counts first
        cur.execute("""
            SELECT entry_type_name, COUNT(DISTINCT title) as count 
            FROM dwh.entry_details_vw 
            GROUP BY entry_type_name 
            ORDER BY entry_type_name
        """)
        total_type_counts = dict(cur.fetchall())
        entry_types = list(total_type_counts.keys())

        # Build search conditions
        search_conditions = []
        params = []
        
        if title_query:
            search_conditions.append("LOWER(title) LIKE LOWER(%s)")
            params.append(f"%{title_query}%")
            
        if author_query:
            search_conditions.append("LOWER(author_name) LIKE LOWER(%s)")
            params.append(f"%{author_query}%")

        if doi_query:
            search_conditions.append("doi = %s")
            params.append(doi_query)

        # Build type filter condition
        if selected_types and "all" not in selected_types:
            search_conditions.append("entry_type_name = ANY(%s)")
            params.append(selected_types)

        # Main query with author grouping
        where_clause = f"WHERE {' AND '.join(search_conditions)}" if search_conditions else ""
        sql_query = f"""
            WITH GroupedEntries AS (
                SELECT DISTINCT ON (title)
                    title, entry_type_name, doi, publication_date, publisher,
                    reference_count, is_referenced_by_count, organization_name,
                    container_title, score, volume, issue, language, isbn,
                    page, abstract, citations, cited_by,
                    author_name
                FROM dwh.entry_details_vw
                WHERE is_primary_author = true
                {' AND ' + ' AND '.join(search_conditions) if search_conditions else ''}
            ),
            AuthorDetails AS (
                SELECT 
                    g.*,
                    json_agg(
                        DISTINCT jsonb_build_object(
                            'name', a.author_name,
                            'orcid', a.orcid,
                            'is_primary', a.is_primary_author
                        )
                    )::json as author_details
                FROM GroupedEntries g
                JOIN dwh.entry_details_vw a ON g.title = a.title
                GROUP BY g.title, g.entry_type_name, g.doi, g.publication_date, g.publisher,
                         g.reference_count, g.is_referenced_by_count, g.organization_name,
                         g.container_title, g.score, g.volume, g.issue, g.language, g.isbn,
                         g.page, g.abstract, g.citations, g.cited_by, g.author_name
            )
            SELECT * FROM AuthorDetails
            ORDER BY title
            LIMIT %s OFFSET %s
        """
        params.extend([per_page, offset])

        # Build a second WHERE clause that matches the main query's logic,
        # but only include is_primary_author condition when there are search conditions
        if search_conditions:
            filtered_where_clause = "WHERE is_primary_author = true AND " + " AND ".join(search_conditions)
        else:
            filtered_where_clause = ""
            
        # Keep the params list for the filtered‑count query in sync
        filtered_params = tuple(params[:-2]) if search_conditions else ()

        filtered_count_sql = f"""
            SELECT entry_type_name, COUNT(DISTINCT title) AS count
            FROM dwh.entry_details_vw
            {filtered_where_clause}
            GROUP BY entry_type_name
        """
        cur.execute(filtered_count_sql, filtered_params)

        filtered_type_counts = dict(cur.fetchall())

        # Execute main query
        cur.execute(sql_query, tuple(params))
        rows = cur.fetchall()
        columns = [desc[0] for desc in cur.description]
        entries = [dict(zip(columns, row)) for row in rows] if rows else []
        # DOIs actually rendered in this view (used for conditional buttons)
        visible_dois = {e["doi"] for e in entries if e.get("doi")}

        # ---------------------------------------------------------------
        # Also add DOIs that appear in citations/cited_by lists *if*
        # they are present anywhere in the database.
        # ---------------------------------------------------------------
        candidate_dois = set()

        for e in entries:
            for key in ("citations", "cited_by"):
                value = e.get(key)
                if not value:
                    continue

                # The column can be a JSON string, a Python list, or a plain DOI.
                if isinstance(value, list):
                    candidate_dois.update(value)
                elif isinstance(value, str):
                    try:
                        parsed = json.loads(value)
                        if isinstance(parsed, list):
                            candidate_dois.update(parsed)
                        else:
                            candidate_dois.add(value)
                    except json.JSONDecodeError:
                        candidate_dois.add(value)

        # Remove None / empty strings
        candidate_dois = {d for d in candidate_dois if d}

        if candidate_dois:
            # Build parameter placeholders – one %s per DOI
            placeholders = ",".join(["%s"] * len(candidate_dois))
            # Query against the same view used elsewhere
            cur.execute(
                f"SELECT DISTINCT doi FROM dwh.entry_details_vw WHERE doi IN ({placeholders})",
                tuple(candidate_dois),
            )
            found_dois = {row[0] for row in cur.fetchall()}
            visible_dois.update(found_dois)

    except psycopg2.Error as e:
        print(f"Database query error: {e}")
        entries = []
        entry_types = []
    finally:
        cur.close()
        conn.close()

    return render_template(
        "index.html",
        entries=entries,
        entry_types=entry_types,
        type_counts=total_type_counts,
        filtered_type_counts=filtered_type_counts,
        selected_types=selected_types,
        title_query=title_query,
        author_query=author_query,
        doi_query=doi_query,
        page=page,
        per_page=per_page,
        entries_count=len(entries),
        visible_dois=visible_dois,
    )

# API Endpoints
@app.route("/api/entries", methods=["GET"])
def api_get_entries():
    """API to fetch bibliographic records with pagination."""
    general_query = request.args.get("q", "").strip()
    title_query = request.args.get("title", "").strip()
    author_query = request.args.get("author", "").strip()
    page = int(request.args.get("page", 0))  # Get the page number, default to 0
    limit = 10  # Changed from 200 to 10 records per page
    offset = page * limit  # Calculate offset for pagination

    conn = get_db_connection()
    if not conn:
        return jsonify({"error": "Database connection error"}), 500

    try:
        cur = conn.cursor()

        sql_query = f"""
            SELECT DISTINCT ON (title, author_name) {SELECTED_COLUMNS}
            FROM dwh.entry_details_vw
            WHERE (%s = '' OR title ILIKE %s OR author_name ILIKE %s OR publisher ILIKE %s)
            AND (%s = '' OR title ILIKE %s)
            AND (%s = '' OR author_name ILIKE %s)
            ORDER BY title, author_name, organization_name
            LIMIT {limit} OFFSET {offset}
        """

        cur.execute(sql_query, (
            general_query, f"%{general_query}%", f"%{general_query}%", f"%{general_query}%",
            title_query, f"%{title_query}%",
            author_query, f"%{author_query}%"
        ))

        rows = cur.fetchall()
        columns = [desc[0] for desc in cur.description]
        results = [dict(zip(columns, row)) for row in rows] if rows else []

    except psycopg2.Error as e:
        print(f"Database query error: {e}")
        results = []
    finally:
        cur.close()
        conn.close()

    return jsonify(results)

if __name__ == "__main__":
    app.run(debug=True)