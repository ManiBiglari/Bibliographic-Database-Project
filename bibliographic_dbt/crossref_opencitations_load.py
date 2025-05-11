import requests
import psycopg2
import json
import logging
import os
import pandas as pd
import urllib.parse
import subprocess
import sys

# Logging setup
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger()

# Database connection setup
def get_db_connection():
    """Establish a database connection."""
    return psycopg2.connect(
        dbname=os.getenv("DB_NAME", "bibliographic_db"),
        user=os.getenv("DB_USER", "admin"),
        password=os.getenv("DB_PASSWORD", "123456"),
        host=os.getenv("DB_HOST", "localhost"),
        port=os.getenv("DB_PORT", "5432")
    )

# Fetch data from Crossref API
def fetch_crossref_data(query, rows, author=None):
    """Fetch data from the Crossref API with optional author filtering."""
    base_url = f"https://api.crossref.org/works?query={urllib.parse.quote(query)}&rows={rows}"
    if author:
        base_url += f"&query.author={urllib.parse.quote(author)}"
    try:
        logger.info(f"Fetching data from Crossref API with query: '{query}', author: '{author}', records: {rows}...")
        response = requests.get(base_url)
        response.raise_for_status()
        return response.json()
    except requests.exceptions.RequestException as e:
        logger.error(f"Error fetching data from API: {e}")
        exit(1)

# Fetch cited_by data
def fetch_cited_by(doi):
    """Fetch a list of DOIs that cite the given publication using OpenCitations API."""
    url = f"https://opencitations.net/index/api/v1/citations/{doi}"
    try:
        response = requests.get(url)
        response.raise_for_status()
        cited_by_items = response.json()
        return [item.get("citing", None) for item in cited_by_items if item.get("citing")]
    except requests.exceptions.RequestException as e:
        logger.error(f"Error fetching cited_by data for {doi}: {e}")
        return []

# Format publication date
def format_date(date_parts):
    """Format the issued date from date-parts."""
    if date_parts and isinstance(date_parts[0][0], int):
        if len(date_parts[0]) == 1:
            return f"{date_parts[0][0]}-01-01"
        elif len(date_parts[0]) == 2:
            return f"{date_parts[0][0]}-{date_parts[0][1]:02d}-01"
        elif len(date_parts[0]) == 3:
            return f"{date_parts[0][0]}-{date_parts[0][1]:02d}-{date_parts[0][2]:02d}"
    return None

# Extract authors
def extract_authors(authors_data):
    """Extract author details as a list of dictionaries."""
    authors = []
    for author in authors_data:
        full_name = f"{author.get('given', 'Unknown')} {author.get('family', 'Unknown')}"
        orcid = author.get("ORCID", None)
        affiliations = [aff.get('name') for aff in author.get("affiliation", []) if aff.get('name')]
        authors.append({
            "name": full_name,
            "orcid": orcid,
            "affiliations": affiliations if affiliations else None,
        })
    return authors

# Insert data into the database
def insert_into_database(cursor, items):
    """Insert data into the staging table with citations and cited_by data."""
    for item in items:
        try:
            doi = item.get("DOI", None)
            title = item.get("title", ["Unknown"])[0]
            publisher = item.get("publisher", "Unknown")
            type_ = item.get("type", "Unknown")
            score = item.get("score", None)
            container_title = item.get("container-title", ["Unknown"])[0] if item.get("container-title") else None
            page = item.get("page", None)
            isbn = json.dumps(item.get("ISBN", []))
            abstract = item.get("abstract", None)
            reference_count = item.get("reference-count", None)
            is_referenced_by_count = item.get("is-referenced-by-count", None)
            volume = item.get("volume", None)
            issue = item.get("issue", None)
            language = item.get("language", None)
            issued_date = format_date(item.get("issued", {}).get("date-parts", [[None]]))

            authors = extract_authors(item.get("author", []))
            authors_json = json.dumps(authors)

            # Extract and log citations (references) list
            references = item.get("reference", [])
            citations_list = [ref.get("DOI") for ref in references if ref.get("DOI")]
            citations_json = json.dumps(citations_list) if citations_list else None  # Insert NULL if empty

            logger.info(f"DOI: {doi} - Citations Found: {len(citations_list)}")

            # Fetch and log cited_by data from OpenCitations API
            cited_by_list = fetch_cited_by(doi) if doi else []
            cited_by_json = json.dumps(cited_by_list) if cited_by_list else None  # Insert NULL if empty

            logger.info(f"DOI: {doi} - Cited By Found: {len(cited_by_list)}")

            # Insert publication data
            cursor.execute("""
                INSERT INTO raw.raw_crossref (
                    doi, title, publisher, type, score, issued, container_title, page, isbn,
                    reference_count, is_referenced_by_count, citations, cited_by, volume, issue,
                    language, publication_date, authors, abstract, raw_data
                )
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s);
            """, (
                doi, title, publisher, type_, score, issued_date, container_title, page, isbn, 
                reference_count, is_referenced_by_count, citations_json, cited_by_json, volume,
                issue, language, None, authors_json, abstract, json.dumps(item)
            ))
            
            # Debug log for values being inserted
            logger.debug(f"Values being inserted: ({doi}, {title}, {publisher}, {type_}, {score}, "
                         f"{issued_date}, {container_title}, {page}, {isbn}, {reference_count}, "
                         f"{is_referenced_by_count}, {citations_json}, {cited_by_json}, {volume}, "
                         f"{issue}, {language}, None, {authors_json}, {abstract}, {json.dumps(item)})")

        except Exception as e:
            logger.error(f"Error processing record for DOI {doi}: {e}")
            continue

# Trigger dbt run
def trigger_dbt():
    """Trigger dbt run after new data is inserted."""
    dbt_profiles_dir = os.getenv("DBT_PROFILES_DIR", os.path.expanduser("~/.dbt"))
    if not os.path.exists(dbt_profiles_dir):
        logger.error(f"dbt profiles directory '{dbt_profiles_dir}' does not exist.")
        return

    try:
        logger.info("Triggering dbt run...")
        result = subprocess.run(
            ["dbt", "run", "--profiles-dir", dbt_profiles_dir],
            check=True,
            text=True,
            capture_output=True  # Capture stdout and stderr
        )
        logger.info("dbt run executed successfully.")
        logger.debug(f"dbt output:\n{result.stdout}")
    except subprocess.CalledProcessError as e:
        logger.error(f"dbt run failed with error: {e}")
        logger.error(f"dbt stdout:\n{e.stdout}")
        logger.error(f"dbt stderr:\n{e.stderr}")

# Main function
def main():
    """Main function to orchestrate fetching and inserting data."""
    conn = get_db_connection()
    cursor = conn.cursor()

    # Get user input for query, number of rows, and author filter
    query = input("Enter search criteria (e.g., 'machine learning'): ").strip()
    rows = input("Enter the number of records to fetch (e.g., 100): ").strip()
    if not rows.isdigit() or int(rows) <= 0:
        logger.error("Invalid number of rows. Please enter a positive integer.")
        return
    rows = int(rows)

    author = input("Filter by author (leave blank for no filter): ").strip()

    # Fetch data
    data = fetch_crossref_data(query=query, rows=rows, author=author)
    items = data['message']['items']

    # Preview data
    preview_data = [{
                     "Title": item.get("title", ["Unknown"])[0],
                     "Authors": extract_authors(item.get("author", [])),
                     "DOI": item.get("DOI", None),
                     "Publisher": item.get("publisher", "Unknown"),
                     "Issued Date": format_date(item.get("issued", {}).get("date-parts", [[None]]))
                     } for item in items[:5]]
    preview_df = pd.DataFrame(preview_data)
    print("\nPreview of fetched data:")
    print(preview_df)

    # Ask for user confirmation before inserting data
    user_input = input("\nDo you want to insert this data into the database? (yes/no): ").strip().lower()
    if user_input != 'yes':
        logger.info("Insertion aborted by the user.")
        conn.close()
        return

    # Ask if the user wants to delete existing raw data before inserting new data
    delete_input = input("\nDo you want to delete existing raw data before inserting new data? (yes/no): ").strip().lower()
    if delete_input == 'yes':
        try:
            logger.info("Truncating table: raw.raw_crossref...")
            cursor.execute("TRUNCATE TABLE raw.raw_crossref RESTART IDENTITY CASCADE;")
            conn.commit()
            logger.info("Table truncated successfully.")
        except Exception as e:
            logger.error(f"Error truncating table: {e}")
            conn.close()
            return

    # Insert data
    insert_into_database(cursor, items)

    # Commit and close
    try:
        conn.commit()
        logger.info("Data successfully inserted into the database.")
    except Exception as e:
        logger.error(f"Error committing transaction: {e}")
    finally:
        cursor.close()
        conn.close()

    # Trigger dbt run after commit
    trigger_dbt()

if __name__ == "__main__":
    # If the script is called with "test-dbt", only run trigger_dbt()
    if len(sys.argv) > 1 and sys.argv[1] == "test-dbt":
        trigger_dbt()
    else:
        main()