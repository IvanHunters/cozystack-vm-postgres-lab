"""Minimal demo service: a VM-hosted web app that stores records in a
managed PostgreSQL database running in the same Cozystack tenant.

Connection parameters are taken from the standard libpq environment
variables (PGHOST, PGPORT, PGUSER, PGPASSWORD, PGDATABASE). They are set in
/etc/app.env, populated from the managed Postgres credentials secret. Using
the libpq variables avoids URL-encoding issues with generated passwords."""
import psycopg
from flask import Flask, jsonify, request

app = Flask(__name__)


def init_db():
    with psycopg.connect() as conn:
        conn.execute(
            "CREATE TABLE IF NOT EXISTS items ("
            "id serial PRIMARY KEY, "
            "name text NOT NULL, "
            "created_at timestamptz NOT NULL DEFAULT now())"
        )
        conn.commit()


@app.get("/health")
def health():
    with psycopg.connect() as conn:
        conn.execute("SELECT 1")
    return {"status": "ok"}


@app.get("/items")
def list_items():
    with psycopg.connect() as conn:
        rows = conn.execute(
            "SELECT id, name, created_at FROM items ORDER BY id"
        ).fetchall()
    return jsonify(
        [
            {"id": r[0], "name": r[1], "created_at": r[2].isoformat()}
            for r in rows
        ]
    )


@app.post("/items")
def add_item():
    payload = request.get_json(force=True) or {}
    name = payload.get("name")
    if not name:
        return {"error": "name is required"}, 400
    with psycopg.connect() as conn:
        row = conn.execute(
            "INSERT INTO items (name) VALUES (%s) RETURNING id", (name,)
        ).fetchone()
        conn.commit()
    return {"id": row[0], "name": name}, 201


if __name__ == "__main__":
    init_db()
    app.run(host="0.0.0.0", port=8080)
