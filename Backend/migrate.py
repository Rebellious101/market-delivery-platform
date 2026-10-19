import os
from dotenv import load_dotenv
import mysql.connector

load_dotenv()

def run_migrations():
    conn = mysql.connector.connect(
        host=os.getenv("DB_HOST", "localhost"),
        user=os.getenv("DB_USER", "market_admin"),
        password=os.getenv("DB_PASSWORD", ""),
        database=os.getenv("DB_NAME", "market_db")
    )
    cursor = conn.cursor()

    def add_column_if_not_exists(table: str, column: str, col_definition: str):
        cursor.execute(f"SHOW COLUMNS FROM {table} LIKE %s", (column,))
        if not cursor.fetchone():
            print(f"Adding column {column} to {table}...")
            cursor.execute(f"ALTER TABLE {table} ADD COLUMN {column} {col_definition}")
            conn.commit()
        else:
            print(f"Column {column} already exists in {table}.")

    # Add user_id, shipping_address, and status to orders
    add_column_if_not_exists("orders", "user_id", "INT NULL")
    add_column_if_not_exists("orders", "shipping_address", "TEXT NULL")
    add_column_if_not_exists("orders", "status", "VARCHAR(50) NOT NULL DEFAULT 'Hazırlanıyor'")

    # Add indexes if not already present
    indexes = [
        ("products", "idx_products_cat_active", "(category_id, active)"),
        ("orders", "idx_orders_user_id", "(user_id)"),
        ("order_items", "idx_order_items_order_id", "(order_id)")
    ]

    for table, index_name, columns in indexes:
        cursor.execute(f"SHOW INDEX FROM {table} WHERE Key_name = %s", (index_name,))
        if not cursor.fetchone():
            print(f"Creating index {index_name} on {table}{columns}...")
            cursor.execute(f"CREATE INDEX {index_name} ON {table} {columns}")
            conn.commit()
        else:
            print(f"Index {index_name} already exists on {table}.")

    cursor.close()
    conn.close()
    print("All migrations executed successfully!")

if __name__ == "__main__":
    run_migrations()
