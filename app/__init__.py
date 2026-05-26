from flask import Flask
from flask_sqlalchemy import SQLAlchemy
from flask_migrate import Migrate
from config import Config
from sqlalchemy.pool import NullPool

db = SQLAlchemy()
migrate = Migrate()

def create_app(testing=False):
    app = Flask(__name__)

    app.config.from_object(Config)

    if testing:
        app.config['TESTING'] = True
        app.config['SQLALCHEMY_ENGINE_OPTIONS'] = {
            'poolclass': NullPool,
            'connect_args': {'connect_timeout': 10}
        }

    db.init_app(app)

    if not testing:
        migrate.init_app(app, db)

    from app.routes import api
    app.register_blueprint(api)

    return app
