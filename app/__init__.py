from flask import Flask
from flask_sqlalchemy import SQLAlchemy
from flask_migrate import Migrate
from config import Config

db = SQLAlchemy()
migrate = Migrate()

def create_apptesting=(False):
    app = Flask(__name__)
    app.config.from_object(Config)
    db.init_app(app)
    if not testing:
        migrate.init_app(app, db)
    from app.routes import api
    app.register_blueprint(api)
    return app
