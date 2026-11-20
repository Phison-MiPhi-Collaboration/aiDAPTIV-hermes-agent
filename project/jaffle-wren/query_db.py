import duckdb
import json
import sys
import os

db_path = "C:/Users/miphi/hermes/jaffle_shop_duckdb/jaffle_shop.duckdb"

def run_query(sql):
    try:
        con = duckdb.connect(db_path)
        res = con.execute(sql).fetchall()
        
        # Get column names
        cols = [desc[0] for desc in con.description]
        
        # Convert to list of dicts
        results = []
        for row in res:
            results.append(dict(zip(cols, row)))
            
        print(json.dumps(results, indent=2, default=str))
        con.close()
    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)

if __name__ == "__main__":
    if len(sys.argv) > 1:
        # If --query is provided, use the following argument
        if sys.argv[1] == "--query" and len(sys.argv) > 2:
            run_query(sys.argv[2])
        else:
            # Otherwise assume the first arg is the query
            run_query(sys.argv[1])
    else:
        # Default query for testing
        run_query("SELECT count(*) FROM main.customers")

