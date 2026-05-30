"""
CloudMart Product Service
Manages product catalogue: CRUD operations, search, category filtering.

Data Store:
  - Default: In-memory dictionary (for local dev / Docker Compose)
  - Cloud:   Set STORE_BACKEND=dynamodb via env var
             to use Amazon DynamoDB (requires IRSA / workload identity)
"""

import os
import uuid
import logging
from datetime import datetime
from decimal import Decimal
from flask import Flask, jsonify, request, abort

# ---------------------------------------------------------------------------
# App setup
# ---------------------------------------------------------------------------
app = Flask(__name__)
app.config["JSON_SORT_KEYS"] = False

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger("product-service")

# X-Ray tracing (no-op when not running on AWS)
try:
    from aws_xray_sdk.core import xray_recorder, patch_all
    from aws_xray_sdk.ext.flask.middleware import XRayMiddleware
    xray_recorder.configure(service="product-service")
    XRayMiddleware(app, xray_recorder)
    patch_all()
    logger.info("AWS X-Ray tracing enabled")
except Exception:
    logger.info("AWS X-Ray SDK not available — tracing disabled")

# ---------------------------------------------------------------------------
# Seed data
# ---------------------------------------------------------------------------
SEED_PRODUCTS = [
    {
        "id": "prod-001",
        "name": "Wireless Bluetooth Headphones",
        "description": "Premium noise-cancelling over-ear headphones with 30-hour battery life",
        "price": 79.99,
        "category": "electronics",
        "stock": 150,
        "imageUrl": "/images/headphones.jpg",
        "createdAt": "2025-01-15T10:00:00Z",
    },
    {
        "id": "prod-002",
        "name": "Organic Ceylon Tea (100 bags)",
        "description": "Premium hand-picked Ceylon black tea from Nuwara Eliya estates",
        "price": 12.99,
        "category": "food",
        "stock": 500,
        "imageUrl": "/images/ceylon-tea.jpg",
        "createdAt": "2025-01-15T10:00:00Z",
    },
    {
        "id": "prod-003",
        "name": "USB-C Laptop Stand",
        "description": "Adjustable aluminium stand with integrated USB-C hub (HDMI, USB 3.0, PD charging)",
        "price": 49.99,
        "category": "electronics",
        "stock": 75,
        "imageUrl": "/images/laptop-stand.jpg",
        "createdAt": "2025-01-15T10:00:00Z",
    },
    {
        "id": "prod-004",
        "name": "Handloom Cotton Sarong",
        "description": "Traditional Sri Lankan handloom sarong, 100% cotton, machine washable",
        "price": 24.99,
        "category": "clothing",
        "stock": 200,
        "imageUrl": "/images/sarong.jpg",
        "createdAt": "2025-01-15T10:00:00Z",
    },
    {
        "id": "prod-005",
        "name": "Mechanical Keyboard (TKL)",
        "description": "Tenkeyless mechanical keyboard with Cherry MX Brown switches, RGB backlight",
        "price": 89.99,
        "category": "electronics",
        "stock": 60,
        "imageUrl": "/images/keyboard.jpg",
        "createdAt": "2025-01-15T10:00:00Z",
    },
    {
        "id": "prod-006",
        "name": "Coconut Oil (Cold Pressed, 500ml)",
        "description": "Virgin cold-pressed coconut oil from Southern Province, Sri Lanka",
        "price": 8.99,
        "category": "food",
        "stock": 300,
        "imageUrl": "/images/coconut-oil.jpg",
        "createdAt": "2025-01-15T10:00:00Z",
    },
]


# ---------------------------------------------------------------------------
# Helper: normalise DynamoDB Decimal types to Python float/int
# ---------------------------------------------------------------------------
def _deserialize(item):
    if item is None:
        return None
    result = {}
    for k, v in item.items():
        if isinstance(v, Decimal):
            result[k] = int(v) if v == v.to_integral_value() else float(v)
        else:
            result[k] = v
    return result


# ---------------------------------------------------------------------------
# In-memory store (local dev / Docker Compose)
# ---------------------------------------------------------------------------
class InMemoryStore:
    def __init__(self):
        self.products = {p["id"]: dict(p) for p in SEED_PRODUCTS}

    def get_all(self, category=None, search=None):
        results = list(self.products.values())
        if category:
            results = [p for p in results if p["category"] == category]
        if search:
            q = search.lower()
            results = [
                p for p in results
                if q in p["name"].lower() or q in p["description"].lower()
            ]
        return results

    def get_by_id(self, product_id):
        return self.products.get(product_id)

    def create(self, data):
        product_id = f"prod-{uuid.uuid4().hex[:6]}"
        product = {
            "id": product_id,
            "name": data["name"],
            "description": data.get("description", ""),
            "price": float(data["price"]),
            "category": data.get("category", "general"),
            "stock": int(data.get("stock", 0)),
            "imageUrl": data.get("imageUrl", ""),
            "createdAt": datetime.utcnow().isoformat() + "Z",
        }
        self.products[product_id] = product
        return product

    def update(self, product_id, data):
        if product_id not in self.products:
            return None
        product = self.products[product_id]
        for key in ["name", "description", "price", "category", "stock", "imageUrl"]:
            if key in data:
                product[key] = data[key]
        product["updatedAt"] = datetime.utcnow().isoformat() + "Z"
        return product

    def delete(self, product_id):
        return self.products.pop(product_id, None) is not None

    def check_stock(self, product_id, quantity):
        product = self.products.get(product_id)
        if not product:
            return False
        return product["stock"] >= quantity

    def decrement_stock(self, product_id, quantity):
        product = self.products.get(product_id)
        if product and product["stock"] >= quantity:
            product["stock"] -= quantity
            return True
        return False


# ---------------------------------------------------------------------------
# DynamoDB store (AWS production)
# ---------------------------------------------------------------------------
class DynamoDBStore:
    """
    AWS DynamoDB adapter.
    Requires: STORE_BACKEND=dynamodb, DYNAMODB_TABLE=<table-name>, AWS_REGION
    Credentials provided automatically via IRSA (IAM Roles for Service Accounts).
    """

    def __init__(self):
        import boto3
        from boto3.dynamodb.conditions import Attr
        self._Attr = Attr
        region = os.environ.get("AWS_REGION", "us-east-1")
        table_name = os.environ["DYNAMODB_TABLE"]
        self.table = boto3.resource("dynamodb", region_name=region).Table(table_name)
        logger.info(f"DynamoDB store initialised: table={table_name} region={region}")

    def get_all(self, category=None, search=None):
        kwargs = {}
        expressions = []
        if category:
            expressions.append(self._Attr("category").eq(category))
        if search:
            q = search.lower()
            expressions.append(
                self._Attr("name").contains(q) | self._Attr("description").contains(q)
            )
        if expressions:
            from functools import reduce
            import operator
            kwargs["FilterExpression"] = reduce(operator.and_, expressions)

        items = []
        resp = self.table.scan(**kwargs)
        items.extend(resp.get("Items", []))
        while "LastEvaluatedKey" in resp:
            kwargs["ExclusiveStartKey"] = resp["LastEvaluatedKey"]
            resp = self.table.scan(**kwargs)
            items.extend(resp.get("Items", []))
        return [_deserialize(i) for i in items]

    def get_by_id(self, product_id):
        resp = self.table.get_item(Key={"id": product_id})
        return _deserialize(resp.get("Item"))

    def create(self, data):
        product_id = f"prod-{uuid.uuid4().hex[:6]}"
        product = {
            "id": product_id,
            "name": data["name"],
            "description": data.get("description", ""),
            "price": Decimal(str(data["price"])),
            "category": data.get("category", "general"),
            "stock": int(data.get("stock", 0)),
            "imageUrl": data.get("imageUrl", ""),
            "createdAt": datetime.utcnow().isoformat() + "Z",
        }
        self.table.put_item(Item=product)
        return _deserialize(product)

    def update(self, product_id, data):
        if not self.get_by_id(product_id):
            return None
        update_expr = []
        expr_values = {}
        expr_names = {}
        field_map = {
            "name": "#nm", "description": "#desc", "price": "#price",
            "category": "#cat", "stock": "#stk", "imageUrl": "#img",
        }
        name_map = {
            "#nm": "name", "#desc": "description", "#price": "price",
            "#cat": "category", "#stk": "stock", "#img": "imageUrl",
        }
        for key, alias in field_map.items():
            if key in data:
                update_expr.append(f"{alias} = :{key}")
                val = data[key]
                if key == "price":
                    val = Decimal(str(val))
                elif key == "stock":
                    val = int(val)
                expr_values[f":{key}"] = val
                expr_names[alias] = name_map[alias]

        expr_values[":updatedAt"] = datetime.utcnow().isoformat() + "Z"
        update_expr.append("#upd = :updatedAt")
        expr_names["#upd"] = "updatedAt"

        resp = self.table.update_item(
            Key={"id": product_id},
            UpdateExpression="SET " + ", ".join(update_expr),
            ExpressionAttributeValues=expr_values,
            ExpressionAttributeNames=expr_names,
            ReturnValues="ALL_NEW",
        )
        return _deserialize(resp.get("Attributes"))

    def delete(self, product_id):
        if not self.get_by_id(product_id):
            return False
        self.table.delete_item(Key={"id": product_id})
        return True

    def check_stock(self, product_id, quantity):
        product = self.get_by_id(product_id)
        if not product:
            return False
        return product["stock"] >= quantity

    def decrement_stock(self, product_id, quantity):
        from boto3.dynamodb.conditions import Attr
        try:
            self.table.update_item(
                Key={"id": product_id},
                UpdateExpression="SET #stk = #stk - :qty",
                ConditionExpression=Attr("stock").gte(quantity),
                ExpressionAttributeNames={"#stk": "stock"},
                ExpressionAttributeValues={":qty": int(quantity)},
            )
            return True
        except self.table.meta.client.exceptions.ConditionalCheckFailedException:
            return False


# ---------------------------------------------------------------------------
# Store factory
# ---------------------------------------------------------------------------
def create_store():
    backend = os.environ.get("STORE_BACKEND", "memory").lower()
    if backend == "dynamodb":
        return DynamoDBStore()
    logger.info("Using in-memory product store (set STORE_BACKEND=dynamodb for AWS)")
    return InMemoryStore()


store = create_store()

# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------


@app.route("/health")
def health():
    return jsonify({"status": "healthy", "service": "product-service"})


@app.route("/ready")
def ready():
    try:
        store.get_all()
        return jsonify({"status": "ready", "service": "product-service"})
    except Exception as e:
        return jsonify({"status": "not ready", "error": str(e)}), 503


@app.route("/products", methods=["GET"])
@app.route("/api/products", methods=["GET"])
def list_products():
    category = request.args.get("category")
    search = request.args.get("search")
    products = store.get_all(category=category, search=search)
    return jsonify({"products": products, "count": len(products)})


@app.route("/products/<product_id>", methods=["GET"])
@app.route("/api/products/<product_id>", methods=["GET"])
def get_product(product_id):
    product = store.get_by_id(product_id)
    if not product:
        abort(404, description=f"Product {product_id} not found")
    return jsonify(product)


@app.route("/products", methods=["POST"])
@app.route("/api/products", methods=["POST"])
def create_product():
    data = request.get_json()
    if not data or "name" not in data or "price" not in data:
        abort(400, description="Missing required fields: name, price")
    product = store.create(data)
    logger.info(f"Created product: {product['id']} — {product['name']}")
    return jsonify(product), 201


@app.route("/products/<product_id>", methods=["PUT"])
@app.route("/api/products/<product_id>", methods=["PUT"])
def update_product(product_id):
    data = request.get_json()
    if not data:
        abort(400, description="Request body required")
    product = store.update(product_id, data)
    if not product:
        abort(404, description=f"Product {product_id} not found")
    logger.info(f"Updated product: {product_id}")
    return jsonify(product)


@app.route("/products/<product_id>", methods=["DELETE"])
@app.route("/api/products/<product_id>", methods=["DELETE"])
def delete_product(product_id):
    if not store.delete(product_id):
        abort(404, description=f"Product {product_id} not found")
    logger.info(f"Deleted product: {product_id}")
    return jsonify({"message": f"Product {product_id} deleted"}), 200


@app.route("/products/<product_id>/stock", methods=["GET"])
@app.route("/api/products/<product_id>/stock", methods=["GET"])
def check_stock(product_id):
    product = store.get_by_id(product_id)
    if not product:
        abort(404, description=f"Product {product_id} not found")
    return jsonify(
        {"productId": product_id, "stock": product["stock"], "available": product["stock"] > 0}
    )


@app.route("/products/<product_id>/stock/decrement", methods=["POST"])
@app.route("/api/products/<product_id>/stock/decrement", methods=["POST"])
def decrement_stock(product_id):
    data = request.get_json() or {}
    quantity = int(data.get("quantity", 1))
    if not store.decrement_stock(product_id, quantity):
        abort(409, description=f"Insufficient stock for product {product_id}")
    logger.info(f"Decremented stock for {product_id} by {quantity}")
    return jsonify({"message": "Stock updated", "productId": product_id})


@app.route("/categories", methods=["GET"])
@app.route("/api/categories", methods=["GET"])
def list_categories():
    products = store.get_all()
    categories = sorted(set(p["category"] for p in products))
    return jsonify({"categories": categories})


# ---------------------------------------------------------------------------
# Error handlers
# ---------------------------------------------------------------------------


@app.errorhandler(400)
def bad_request(e):
    return jsonify({"error": "Bad Request", "message": str(e.description)}), 400


@app.errorhandler(404)
def not_found(e):
    return jsonify({"error": "Not Found", "message": str(e.description)}), 404


@app.errorhandler(409)
def conflict(e):
    return jsonify({"error": "Conflict", "message": str(e.description)}), 409


@app.errorhandler(500)
def internal_error(e):
    logger.error(f"Internal Server Error: {e}")
    return jsonify({"error": "Internal Server Error"}), 500


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8001))
    debug = os.environ.get("FLASK_DEBUG", "false").lower() == "true"
    logger.info(f"Starting product-service on port {port}")
    app.run(host="0.0.0.0", port=port, debug=debug)
