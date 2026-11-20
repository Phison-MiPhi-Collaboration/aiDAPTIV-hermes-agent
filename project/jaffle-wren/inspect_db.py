import duckdb
import json
import os

# Use a more Windows-friendly path
db_path = "C:/Users/miphi/hermes/jaffle_shop_duckdb/jaffle_shop.duckdb"

try:
    con = duckdb.connect(db_path)
    
    # Get all tables
    tables_query = "SELECT table_name FROM information_schema.tables WHERE table_schema = 'main'"
    tables = [row[0] for row in con.execute(tables_query).fetchall()]
    
    result = {
        "all_tables": tables,
        "targets": {}
    }
    
    target_tables = [t for t in tables if t in ['customers', 'orders']]
    
    for table in target_tables:
        # Get columns
        cols_query = f"SELECT column_name, data_type FROM information_schema.columns WHERE table_name = '{table}'"
        columns = []
        for row in con.execute(cols_query).fetchall():
            columns.append({"name": row[0], "type": row[1]})
            
        result["targets"][table] = {
            "columns": columns
        }
        
    print(json.dumps(result, indent=2))
    con.close()

except Exception as e:
    print(f"Error: {e}")

